# k3s cluster on plain Azure VMs (1 server + N agents).

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

locals {
  name = var.cluster_name
  tags = merge({ project = "scalesafe", cluster = var.cluster_name, managed_by = "terraform" }, var.tags)
}

resource "azurerm_resource_group" "this" {
  name     = "${local.name}-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "${local.name}-vnet"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_subnet" "nodes" {
  name                 = "nodes"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_cidr]
}

resource "azurerm_network_security_group" "nodes" {
  name                = "${local.name}-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  security_rule {
    name                       = "ssh-admin"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.admin_cidrs
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "kubeapi-admin"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6443"
    source_address_prefixes    = var.admin_cidrs
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "web"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefixes    = var.web_cidrs
    destination_address_prefix = "*"
  }

  # Intra-VNet traffic (flannel VXLAN 8472/udp, kubelet 10250, etc.) is allowed by the
  # default AllowVnetInBound rule. Everything else from the Internet is denied by default.
}

resource "azurerm_subnet_network_security_group_association" "nodes" {
  subnet_id                 = azurerm_subnet.nodes.id
  network_security_group_id = azurerm_network_security_group.nodes.id
}

# ---------------------------------------------------------------- server
resource "azurerm_public_ip" "server" {
  name                = "${local.name}-server-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "server" {
  name                = "${local.name}-server-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.nodes.id
    private_ip_address_allocation = "Static"
    private_ip_address            = cidrhost(var.subnet_cidr, 10)
    public_ip_address_id          = azurerm_public_ip.server.id
  }
}

module "server_init" {
  source       = "../k3s-cloudinit"
  role         = "server"
  k3s_version  = var.k3s_version
  k3s_token    = var.k3s_token
  tls_sans     = concat([azurerm_public_ip.server.ip_address], var.extra_tls_sans)
  cloud        = "azure"
  cluster_name = var.cluster_name
}

resource "azurerm_linux_virtual_machine" "server" {
  name                            = "${local.name}-server-0"
  location                        = azurerm_resource_group.this.location
  resource_group_name             = azurerm_resource_group.this.name
  size                            = var.server_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.server.id]
  custom_data                     = base64encode(module.server_init.rendered)
  encryption_at_host_enabled      = var.encryption_at_host
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  tags                            = merge(local.tags, { role = "server" })

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  lifecycle {
    ignore_changes = [custom_data, source_image_reference]
  }
}

# ---------------------------------------------------------------- agents
# Agents get a public IP so they have outbound Internet (new Azure VNets have no default
# outbound access) and can serve ingress. Inbound is still restricted by the NSG.
# For production at scale, swap this for a NAT Gateway + private agents.
resource "azurerm_public_ip" "agent" {
  count               = var.agent_count
  name                = "${local.name}-agent-${count.index}-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "agent" {
  count               = var.agent_count
  name                = "${local.name}-agent-${count.index}-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.nodes.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.agent[count.index].id
  }
}

module "agent_init" {
  source       = "../k3s-cloudinit"
  role         = "agent"
  k3s_version  = var.k3s_version
  k3s_token    = var.k3s_token
  server_url   = "https://${azurerm_network_interface.server.private_ip_address}:6443"
  cloud        = "azure"
  cluster_name = var.cluster_name
}

resource "azurerm_linux_virtual_machine" "agent" {
  count                           = var.agent_count
  name                            = "${local.name}-agent-${count.index}"
  location                        = azurerm_resource_group.this.location
  resource_group_name             = azurerm_resource_group.this.name
  size                            = var.agent_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.agent[count.index].id]
  custom_data                     = base64encode(module.agent_init.rendered)
  encryption_at_host_enabled      = var.encryption_at_host
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  tags                            = merge(local.tags, { role = "agent" })

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  lifecycle {
    ignore_changes = [custom_data, source_image_reference]
  }

  depends_on = [azurerm_linux_virtual_machine.server]
}
