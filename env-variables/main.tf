locals {
    envs = { for tuple in regexall("(.*?)=(.*)", file("${path.module}/../${var.file_name}")) : tuple[0] => tuple[1] }
}