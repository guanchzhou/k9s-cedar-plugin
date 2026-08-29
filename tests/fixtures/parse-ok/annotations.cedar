@id("cluster-admin")
@clusterRole("cluster-admin")
permit (
  principal in Group::"system:masters",
  action,
  resource
);
