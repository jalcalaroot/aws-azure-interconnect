# Two minimal instances whose only job is to prove private connectivity
# works end-to-end over the Interconnect (ICMP + a plain HTTP echo on 8080).
# No SSH/RDP exposed anywhere - matches the "no bastion" decision already
# made for the EKS/AKS work. Both are managed out-of-band (SSM / Run
# Command), so neither security boundary below opens an inbound management
# port, only the test traffic from the other cloud's CIDR.

# --- AWS side ---------------------------------------------------------------

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "poc_instance" {
  name_prefix = "aws-azure-interconnect-poc-"
  description = "PoC instance - no inbound management port, only test traffic from the Azure VNet"
  vpc_id      = module.aws_vpc.vpc_id

  egress {
    description = "HTTPS only - enough for the SSM agent via the NAT Gateway, nothing else needs outbound"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "ICMP from the Azure VNet, over the Interconnect"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [local.azure_vnet_cidr]
  }

  ingress {
    description = "HTTP echo from the Azure VNet, over the Interconnect"
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
  ami                    = data.aws_ssm_parameter.al2023_ami.value
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

  user_data = <<-EOF
    #!/bin/bash
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
    name                       = "allow-icmp-http-from-aws"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = local.aws_vpc_cidr
    destination_address_prefix = "*"
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
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
    #!/bin/bash
    python3 -m http.server 8080 &
  EOF
  )
}
