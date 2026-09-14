# Two minimal Ubuntu 24.04 LTS instances whose only job is to prove private
# connectivity works end-to-end over the Interconnect: ICMP, plus a plain
# HTTP echo listening on 80, 443 and 8080 (443 is NOT real TLS here - same
# plain HTTP echo, just also bound to that port, so the security-group/NSG
# path for an eventual real HTTPS test is already open). Same OS on both
# clouds on purpose, so a ping/curl failure means "network", not "different
# tools on each side". No SSH/RDP exposed anywhere - matches the "no
# bastion" decision already made for the EKS/AKS work: these 2 boxes ARE
# the "bastion" the user asked for, just managed out-of-band (SSM / Run
# Command) instead of an interactive jump host - neither security boundary
# below opens an inbound management port, only the test traffic from the
# other cloud's CIDR.

# --- AWS side ---------------------------------------------------------------

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_security_group" "poc_instance" {
  name_prefix = "aws-azure-interconnect-poc-"
  description = "PoC instance - no inbound management port, only test traffic from the Azure VNet"
  vpc_id      = module.aws_vpc.vpc_id

  egress {
    description = "HTTPS to the internet - enough for the SSM agent and apt via the NAT Gateway"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTP to the internet - apt package mirrors"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "ICMP to the Azure VNet, over the Interconnect - this instance also initiates checks, not just responds"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [local.azure_vnet_cidr]
  }

  egress {
    description = "HTTP/HTTPS/8080 test traffic to the Azure VNet, over the Interconnect"
    from_port   = 80
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [local.azure_vnet_cidr]
  }

  ingress {
    description = "ICMP from the Azure VNet, over the Interconnect"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [local.azure_vnet_cidr]
  }

  ingress {
    description = "HTTP echo (80) from the Azure VNet, over the Interconnect"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [local.azure_vnet_cidr]
  }

  ingress {
    description = "HTTPS echo (443, plain HTTP for now - no cert yet) from the Azure VNet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.azure_vnet_cidr]
  }

  ingress {
    description = "HTTP echo (8080, original test port) from the Azure VNet"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [local.azure_vnet_cidr]
  }

  tags = local.tags
}

resource "aws_iam_role" "ssm" {
  name = "aws-azure-interconnect-poc-ssm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "aws-azure-interconnect-poc-ssm"
  role = aws_iam_role.ssm.name
}

resource "aws_instance" "poc" {
  #checkov:skip=CKV_AWS_126:Detailed (1-min) monitoring has a real per-instance cost (~$2.10/mo) for a throwaway PoC test box - default 5-min monitoring is free and enough to see it's alive
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = "t3.micro"
  subnet_id              = module.aws_vpc.compute_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.poc_instance.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  ebs_optimized          = true # free on Nitro instance types (t3.*) - already the API default, just making the Terraform attribute match reality

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    encrypted = true # AWS-managed key, no extra cost
  }

  # Ubuntu's cloud image ships the SSM agent (snap) but not python3/iputils
  # by default on the minimal server image - install explicitly rather than
  # assume they're there.
  user_data = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y python3 iputils-ping curl net-tools dnsutils traceroute
    python3 -m http.server 80 &
    python3 -m http.server 443 &
    python3 -m http.server 8080 &
  EOF

  tags = merge(local.tags, { Name = "aws-azure-interconnect-poc" })
}

# --- Azure side ---------------------------------------------------------------

resource "azurerm_network_security_group" "poc_vm" {
  name                = "nsg-aws-azure-interconnect-poc"
  location            = var.azure_location
  resource_group_name = var.azure_resource_group_name
  tags                = local.tags

  security_rule {
    name                       = "allow-icmp-from-aws-inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Icmp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = local.aws_vpc_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-http-from-aws-inbound"
    priority                   = 201
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443", "8080"]
    source_address_prefix      = local.aws_vpc_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-icmp-to-aws-outbound"
    priority                   = 200
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Icmp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = local.aws_vpc_cidr
  }

  security_rule {
    name                       = "allow-http-to-aws-outbound"
    priority                   = 201
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443", "8080"]
    source_address_prefix      = "*"
    destination_address_prefix = local.aws_vpc_cidr
  }
}

resource "azurerm_network_interface" "poc_vm" {
  name                = "nic-aws-azure-interconnect-poc"
  location            = var.azure_location
  resource_group_name = var.azure_resource_group_name
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = module.azure_vnet.app_subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "poc_vm" {
  network_interface_id      = azurerm_network_interface.poc_vm.id
  network_security_group_id = azurerm_network_security_group.poc_vm.id
}

resource "azurerm_linux_virtual_machine" "poc" {
  #checkov:skip=CKV_AZURE_50:Bootstrapped via cloud-init (custom_data) on purpose - a Custom Script Extension would be one more billed/managed agent for a single `python3 -m http.server` on a throwaway PoC VM
  name                            = "vm-aws-azure-interconnect-poc"
  resource_group_name             = var.azure_resource_group_name
  location                        = var.azure_location
  size                            = "Standard_B1ls" # cheapest non-retired burstable x64 size - clean per tflint's azurerm ruleset (B1s/B1ms/B2s all flagged retired-or-announced)
  admin_username                  = "azureuser"
  network_interface_ids           = [azurerm_network_interface.poc_vm.id]
  disable_password_authentication = true
  tags                            = local.tags

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.azure_vm_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y python3 iputils-ping curl net-tools dnsutils traceroute
    python3 -m http.server 80 &
    python3 -m http.server 443 &
    python3 -m http.server 8080 &
  EOF
  )
}
