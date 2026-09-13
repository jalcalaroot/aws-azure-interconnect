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
- Validar el Terraform completo (`fmt`/`validate`/`plan`) en una shell donde `terraform` funcione.
- Decidir si esto termina viviendo solo como PoC descartable o si se documenta como arquitectura de referencia (como pasó con Container Apps y AKS/AGIC en el blog).
