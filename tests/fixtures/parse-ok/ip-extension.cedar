permit (
  principal,
  action,
  resource
)
when {
  ip("10.0.0.1").isInRange(ip("10.0.0.0/8"))
};
