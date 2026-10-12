variable "IMAGE" {}
variable "TAG" {}

group "release" {
  targets = ["nginx"]
}

group "ci" {
  targets = ["nginx"]
}

target "nginx" {
  context    = "."
  dockerfile = "docker/production/nginx/Dockerfile"
  tags       = ["${IMAGE}-nginx:${TAG}", "${IMAGE}-nginx:latest"]
}