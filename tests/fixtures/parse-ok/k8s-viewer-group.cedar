permit (
  principal in k8s::Group::"viewers",
  action in [k8s::Action::"get", k8s::Action::"list", k8s::Action::"watch"],
  resource is k8s::Resource
) unless {
  resource.resource == "secrets" &&
  resource.apiGroup == ""
};
