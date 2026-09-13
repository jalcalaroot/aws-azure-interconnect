# aws-azure-interconnect

PoC de conectividad privada AWS ↔ Azure sobre AWS Interconnect / Azure Multicloud Interconnect (ambos en preview, anunciados/documentados agosto 2026). Vive en `multicloud/`, junto a `prowler-multicloud-agent`, no bajo `aws/` ni `azure/` - es intrínsecamente de las dos nubes.

## Decisiones (2026-09-13)

- **Región: us-east-1 ↔ East US.** Es el único par que incluye N. Virginia entre los 4 soportados en el preview (los otros 3: N. California↔West US, Sydney↔Australia East, Frankfurt↔Germany West Central). El usuario pidió explícitamente us-east-1.
- **Ningún recurso de Terraform existe todavía para el Interconnect en sí.** Verificado en vivo (no asumido) contra el registro de Terraform vía `search_providers` del MCP: `hashicorp/aws` 6.64.0 no tiene un resource `interconnect` (sí tiene toda la familia `dx_*` normal), `hashicorp/azurerm` 5.5.0 no tiene nada bajo `multicloud`/`multicloud_interconnect` (sí tiene toda la familia `express_route_*` normal). Ambos recursos de Interconnect se crean a mano - ver runbook en README. Si en una sesión futura estos recursos ya existen en un provider más nuevo, esto se puede migrar a Terraform y el runbook manual se vuelve innecesario.
- **CIDRs no superpuestos a propósito** (`10.100.0.0/16` AWS, `10.200.0.0/16` Azure) - a diferencia de otros repos de este workspace que usan `10.0.0.0/16` en ambos lados porque nunca se conectan directamente, acá sí se conectan, así que superponer rompería el ruteo.
- **`az_count = 1`** en el módulo `aws-vpc` (default es 3) - el NAT Gateway regional se factura por AZ activa, y este PoC no necesita alta disponibilidad, solo probar que la conectividad funciona. Mismo criterio de costo que ya aplica en `aws-vpc`/`azure-virtual-network` (nada con costo recurrente prendido por defecto si no hace falta).
- **Sin bastion, sin SSH/RDP expuesto** - mismo criterio ya decidido en el trabajo de EKS/AKS (un bastion solo mueve dónde tipeás los comandos, no reduce pasos). Acceso a las 2 instancias de prueba vía SSM (AWS) y Run Command (Azure) - ninguna requiere un puerto de management abierto en el Security Group/NSG, solo el tráfico de prueba (ICMP + 8080) desde el CIDR de la otra nube.
- **VPN Gateway en vez de Transit Gateway** del lado AWS para el DX Gateway association - este PoC es una sola VPC, pagar por un TGW no se justifica solo para este test.
- **ExpressRoute Gateway SKU `Standard`** (la más barata que soporta `type = "ExpressRoute"`) - no se confirmó el precio exacto por hora, queda pendiente antes de aplicar. Es el recurso más caro y más lento (30-60 min de provisioning) de todo el PoC.

## Gotcha: `terraform`/`gcloud` snap binarios no responden en este sandbox

En la sesión donde se escribió este repo, tanto `terraform version` como `gcloud config list` se ejecutaban con exit code distinto de error pero **sin ninguna salida** (ni stdout ni stderr), con y sin sandbox de Claude Code deshabilitado - parece un problema de los paquetes snap en ese entorno, no de permisos. Ningún `.tf` de este repo fue validado con `terraform fmt`/`validate`/`plan` real todavía - correr eso en una shell normal antes del primer `apply`.

## Pendiente

- Confirmar precio exacto del ExpressRoute Gateway SKU `Standard` en `eastus` antes de aplicar.
- Encontrar el comando exacto de AWS CLI / `az` para crear y redimir la activation key del Interconnect (muy nuevo, no confirmado en esta sesión - ver README).
- Decidir si esto termina viviendo solo como PoC descartable o si se documenta como arquitectura de referencia (como pasó con Container Apps y AKS/AGIC en el blog).

## Validación real hecha (2026-09-13), CI y seguridad copiada de los repos hermanos

`terraform`/`gcloud` como snap en este entorno no devuelven nada (ver gotcha arriba) - la validación real se hizo corriendo `hashicorp/terraform:1.10` vía Docker (`docker run --rm -v $(pwd):/wd -w /wd hashicorp/terraform:1.10 ...`), que sí funciona sin problema. Con eso: `fmt` (aplicó 2 correcciones de alineación), `init -backend=false` (bajó los 2 módulos + providers `aws` 6.64.0 / `azurerm` 5.5.0 reales), y `validate` (limpio, solo warnings preexistentes del módulo `azure-virtual-network` sobre `public_network_access_enabled` deprecado - no es de este repo).

`tflint` (binario real en `/usr/local/bin/tflint`, no snap) encontró que `Standard_B1s` está retirado/anunciado para retiro - se probó `Standard_B2s`/`Standard_B1ms` (también flaggeados) hasta dar con `Standard_B1ls`, que queda limpio y sigue siendo x64 (compatible con la imagen Canonical Jammy gen2 usada) - no confundir con la familia `Bxats`/ARM.

`checkov` (instalado en un venv aislado, `pip` del sistema es "externally managed") encontró 8 findings reales, 6 arreglados de verdad y 2 pares dejados con `#checkov:skip` justificado:

- **Arreglado**: SG de la instancia EC2 con egress `0.0.0.0/0` en todos los puertos → acotado a 443/tcp (alcanza para SSM). IMDSv2 forzado (`metadata_options.http_tokens = "required"`). Root volume cifrado (`root_block_device.encrypted = true`, sin costo extra - KMS default de AWS). `ebs_optimized = true` en la instancia (gratis en t3.*, Nitro ya lo hace por default a nivel de API, esto solo alinea el atributo de Terraform).
- **Skip con justificación** (mismo patrón que `aws-vpc`/`aws-eks-cluster`, `#checkov:skip=<ID>:<razón>` inline): monitoreo detallado de EC2 (`CKV_AWS_126`, ~$2.10/mes que no aporta nada a un PoC descartable), extensiones de VM en Azure (`CKV_AZURE_50`, `custom_data`/cloud-init es intencional en vez de una Custom Script Extension), y source de los 2 módulos sin commit hash (`CKV_TF_1` × 2, es la convención documentada del workspace - versionado por git tag, no por hash).

Resultado final: `tflint` 0 issues, `checkov` 36 passed / 0 failed / 4 skipped.

CI copiado 1:1 de `aws-vpc`/`azure-virtual-network` (mismos SHAs de Actions ya pineados por ellos, no re-verificados de nuevo acá): `gitleaks.yml`, `scorecard.yml`, `.pre-commit-config.yaml`, `.github/dependabot.yml` (terraform + github-actions), `SECURITY.md`. **A propósito NO se copió el patrón `terraform-plan.yml`/`terraform-apply.yml`** de `aws-eks-cluster`/`azure-aks-cluster` - el usuario pidió explícitamente evitar cualquier deploy automático por ahora, y esos workflows necesitarían credenciales/OIDC reales de AWS y Azure wireados como secrets del repo, algo que no se configuró ni se pidió todavía. `terraform-validate.yml` es intencionalmente validate-only (fmt/validate/tflint/checkov), sin `plan` ni `apply`, sin necesitar ningún secret.

Después de crear el repo en GitHub: branch protection en `main` copiada de `aws-vpc` (`required_status_checks: ["fmt + validate", "gitleaks"]`, `strict: true`, sin admin bypass, sin force-push ni delete). Secret scanning + push protection son automáticos en repos públicos, no necesitan configuración manual.
