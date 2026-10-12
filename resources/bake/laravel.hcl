variable "IMAGE" {}
variable "TAG" {}

group "release" {
  targets = ["nginx", "php-fpm", "php-cli"]
}

group "ci" {
  targets = ["nginx", "php-fpm", "php-cli", "test"]
}

target "nginx" {
  context    = "."
  dockerfile = "docker/production/nginx/Dockerfile"
  tags       = ["${IMAGE}-nginx:${TAG}", "${IMAGE}-nginx:latest"]
}

target "php-fpm" {
  context    = "."
  dockerfile = "docker/production/php-fpm/Dockerfile"
  target     = "production"
  tags       = ["${IMAGE}-php-fpm:${TAG}", "${IMAGE}-php-fpm:latest"]
}

target "php-cli" {
  context    = "."
  dockerfile = "docker/production/php-cli/Dockerfile"
  tags       = ["${IMAGE}-php-cli:${TAG}", "${IMAGE}-php-cli:latest"]
}

target "test" {
  context    = "."
  dockerfile = "docker/testing/Dockerfile"
  tags       = ["ci-test:${TAG}"]
}