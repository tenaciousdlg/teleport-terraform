##################################################################################
# OUTPUTS
##################################################################################

output "access_list_summary" {
  value = {
    team_lists = [
      teleport_access_list.engineering_team.id
    ]

    environment_lists = [
      teleport_access_list.dev_environment.id,
      teleport_access_list.prod_readonly.id,
      teleport_access_list.prod_oncall.id
    ]

    special_lists = [
      teleport_access_list.break_glass.id
    ]

    roles = [
      teleport_role.base_user.id,
      teleport_role.dev_environment_access.id,
      teleport_role.prod_readonly_access.id,
      teleport_role.prod_full_access.id,
      teleport_role.engineering_tools_access.id,
      teleport_role.prod_access_requester.id,
      teleport_role.access_reviewer.id
    ]
  }
}
