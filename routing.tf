# ---------------------------------------------------------------------------
# Gaps de networking reales, encontrados leyendo el código fuente de
# aws-vpc/azure-virtual-network (no asumidos) - ninguno de los security
# groups/NSG alcanza si estas 2 cosas no están:
#
# 1. Route table de la subnet compute: el módulo aws-vpc solo le pone
#    0.0.0.0/0 -> NAT Gateway (route_tables.tf). Sin una ruta explícita a
#    10.200.0.0/16 por el VPN Gateway, el tráfico hacia Azure saldría por
#    el NAT (a la IP pública, no por el Interconnect) o ni saldría.
#
# 2. NACL "private" (compartida por compute+data): su única regla amplia es
#    "todo el tráfico, pero solo si el origen/destino es 10.100.0.0/16" -
#    o sea, tráfico intra-VPC. Todo lo que cruza a 10.200.0.0/16 no matchea
#    ninguna regla y cae en el deny implícito, sin importar lo que diga el
#    Security Group (la NACL es stateless y se evalúa antes, a nivel de
#    subnet - un ALLOW en el SG no compensa un DENY en la NACL).
#    Puntual: la NACL "private" no tiene NINGUNA regla egress de puertos
#    efímeros (1024-65535) hacia afuera - el módulo la diseñó para
#    instancias que solo INICIAN conexiones salientes (a internet vía NAT),
#    no para recibir conexiones entrantes desde fuera de la VPC. Sin esa
#    regla, la respuesta a una conexión que Azure inicia hacia nuestra
#    instancia (SYN-ACK desde el puerto 80/443/8080 hacia el puerto
#    efímero de Azure) queda bloqueada de salida.
#
# El módulo azure-virtual-network, del otro lado, no tiene este problema:
# su route table "rt-app" ya tiene bgp_route_propagation_enabled = true
# (route_tables.tf), así que la ruta a 10.100.0.0/16 se aprende sola por
# BGP en cuanto el circuito conecta. Y su NSG de subnet ("nsg-private")
# permite todo el tráfico Inbound/Outbound con origen/destino "VirtualNetwork"
# - un service tag de Azure que, por diseño, incluye las redes conectadas
# vía ExpressRoute/gateway, no solo la VNet local. No hace falta tocar nada
# ahí.
# ---------------------------------------------------------------------------

data "aws_route_table" "compute" {
  subnet_id = module.aws_vpc.compute_subnet_ids[0]
}

resource "aws_route" "compute_to_azure" {
  route_table_id         = data.aws_route_table.compute.id
  destination_cidr_block = local.azure_vnet_cidr
  gateway_id             = aws_vpn_gateway.poc.id
}

# --- NACL: agregar lo que falta para 10.200.0.0/16, sin tocar lo existente -

resource "aws_network_acl_rule" "private_in_icmp_from_azure" {
  #checkov:skip=CKV_AWS_352:falso positivo - ICMP no tiene puertos, Checkov interpreta from_port/to_port sin setear como "todos los puertos"; mismo patrón que los #checkov:skip ya documentados en aws-vpc/nacl.tf
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 200
  egress         = false
  protocol       = "icmp"
  icmp_type      = -1
  icmp_code      = -1
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
}

resource "aws_network_acl_rule" "private_out_icmp_to_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 200
  egress         = true
  protocol       = "icmp"
  icmp_type      = -1
  icmp_code      = -1
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
}

resource "aws_network_acl_rule" "private_in_ssh_from_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 195 # inbound rule numbers are their own sequence, separate from egress - keep below 200 (icmp) to avoid colliding with it
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 22
  to_port        = 22
}

resource "aws_network_acl_rule" "private_in_http_from_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 201
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 80
  to_port        = 80
}

resource "aws_network_acl_rule" "private_in_https_from_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 202
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 443
  to_port        = 443
}

resource "aws_network_acl_rule" "private_in_8080_from_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 203
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 8080
  to_port        = 8080
}

resource "aws_network_acl_rule" "private_out_ssh_to_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 205 # separate sequence from inbound - just needs to not collide with the other egress rule_numbers on this NACL (200, 211-213, 220)
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 22
  to_port        = 22
}

resource "aws_network_acl_rule" "private_out_http_to_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 211
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 80
  to_port        = 80
}

resource "aws_network_acl_rule" "private_out_https_to_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 212
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 443
  to_port        = 443
}

resource "aws_network_acl_rule" "private_out_8080_to_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 213
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 8080
  to_port        = 8080
}

# La regla que de verdad faltaba: sin esto, la NACL nunca deja salir la
# respuesta (SYN-ACK, etc.) de una conexión que Azure inició hacia nosotros
# - el módulo nunca previó tráfico entrante desde fuera de la VPC.
resource "aws_network_acl_rule" "private_out_ephemeral_to_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 220
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 1024
  to_port        = 65535
}
