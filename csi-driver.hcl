# KV v1 example
path "example-kv/data/password" {
  capabilities = ["read"]
}

# KV v2 example
path "example-kv/data/api-key" {
  capabilities = ["read"]
}

# Allow checking licence status (often needed in some setups)
path "sys/license/status" {
  capabilities = ["read"]
}

# Allow CSI driver to generate AppRole secret IDs and read role ID
path "auth/approle/role/example-role/secret-id" {
  capabilities = ["update"]
}

path "auth/approle/role/example-role/role-id" {
  capabilities = ["read"]
}