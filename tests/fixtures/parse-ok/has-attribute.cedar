permit (
  principal,
  action,
  resource
)
when {
  resource has namespace &&
  resource.namespace == "default"
};
