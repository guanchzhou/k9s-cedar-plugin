permit (
  principal,
  action,
  resource
);
forbid (
  principal,
  action == Action::"delete",
  resource
);
