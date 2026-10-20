variable "dns_adoption_snapshot" {
  description = "첫 import 직전 콘솔의 전체 DNS 설정. 기본값 없이 사람이 확인한 값을 Infisical JSON으로 넣는다."
  type = object({
    override_local_dns = bool
    magic_dns          = bool
    nameservers = list(object({
      address            = string
      use_with_exit_node = bool
    }))
    split_dns = list(object({
      domain = string
      nameservers = list(object({
        address            = string
        use_with_exit_node = bool
      }))
    }))
    search_paths = list(string)
  })
  sensitive = true
  nullable  = false
}
