# Partial backend configuration.
#
# The bucket name is deliberately absent: this repository is public, and the
# state location is not something to advertise. Real values live in a
# gitignored backend.hcl:
#
#     terraform init -backend-config=backend.hcl
#
# For the first disposable build, local state is acceptable -- comment this
# block out and run a plain `terraform init`. Migrate to S3 before calling the
# setup team-ready. State is never committed either way (see .gitignore).

terraform {
  backend "s3" {}
}
