# Azure CLI access via Teleport App Access.
#
# Deploys the documented pattern (docs: enroll-resources/application-access/
# cloud-apis/azure/): an app agent on an Azure VM with a user-assigned
# managed identity (`teleport-azure`, Reader on this resource group) that
# users assume with `tsh apps login azure-cli --azure-identity teleport-azure`.
# CLI/API only by product design — Azure Portal access requires the separate
# Teleport-as-IdP + Entra External ID path.
#
# The agent joins with the native `azure` join method — identity attested by
# Azure, NO join secret, NO token TTL (see cloud-gcp-cli for the history).

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.100"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    teleport = {
      source  = "terraform.releases.teleport.dev/gravitational/teleport"
      version = "~> 18.0"
    }
  }
}

resource "azurerm_resource_group" "demo" {
  name     = var.resource_group_name
  location = var.location
  tags     = { owner = "dlg", purpose = "teleport-demo" }
}

resource "azurerm_user_assigned_identity" "teleport_azure" {
  name                = "teleport-azure"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
}

resource "azurerm_role_assignment" "reader" {
  scope                = azurerm_resource_group.demo.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.teleport_azure.principal_id
}

resource "teleport_provision_token" "azure_join" {
  version = "v2"
  metadata = {
    name        = "azure-cli-join"
    description = "azure join method for the azure-cli app agent"
  }
  spec = {
    roles       = ["App"]
    join_method = "azure"
    azure = {
      allow = [{
        subscription    = var.subscription_id
        resource_groups = [azurerm_resource_group.demo.name]
      }]
    }
  }
}

resource "azurerm_virtual_network" "demo" {
  name                = "vnet-teleport-demo"
  address_space       = ["10.20.0.0/24"]
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
}

resource "azurerm_subnet" "demo" {
  name                 = "agents"
  resource_group_name  = azurerm_resource_group.demo.name
  virtual_network_name = azurerm_virtual_network.demo.name
  address_prefixes     = ["10.20.0.0/26"]
}

resource "azurerm_network_interface" "agent" {
  name                = "nic-teleport-azure-cli"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.demo.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "tls_private_key" "vm" {
  algorithm = "ED25519"
}

resource "azurerm_linux_virtual_machine" "agent" {
  name                = "teleport-azure-cli"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  size                = var.vm_size
  admin_username      = "azureuser"
  tags                = { owner = "dlg", purpose = "teleport-demo" }

  network_interface_ids = [azurerm_network_interface.agent.id]

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.vm.public_key_openssh
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.teleport_azure.id]
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

  custom_data = base64encode(templatefile("${path.module}/userdata.tpl", {
    proxy_address = var.proxy_address
    token_name    = teleport_provision_token.azure_join.metadata.name
    client_id     = azurerm_user_assigned_identity.teleport_azure.client_id
    env           = var.env
    team          = var.team
  }))
}
