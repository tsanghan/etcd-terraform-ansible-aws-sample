#######
# ELB
#######

resource "aws_elb" "etcd" {
    name = "${var.elb_name}"
    listener {
      instance_port = "${var.etcd_client_port}"
      instance_protocol = "TCP"
      lb_port = "${var.etcd_client_port}"
      lb_protocol = "TCP"
    }
    health_check {
      healthy_threshold = 2
      unhealthy_threshold = 2
      timeout = 5
      target = "HTTP:${var.etcd_client_port}/health"
      interval = 30
    }

    cross_zone_load_balancing = true
    instances = ["${aws_instance.etcd.*.id}"]
    subnets = ["${aws_subnet.dmz.*.id}"]
    security_groups = ["${aws_security_group.etcdlb.id}"]

    tags {
      Name = "etcd"
      Owner = "${var.owner}"
    }
}

##############
## Instances
##############

# Instances for etcd
resource "aws_instance" "etcd" {
  count = "${var.node_count}"
  ami = "${var.etcd_ami}"
  instance_type = "${var.etcd_instance_type}"
  availability_zone = "${element(var.zones, count.index)}"
  subnet_id = "${element(aws_subnet.private.*.id, count.index)}"
  key_name = "${var.default_keypair_name}"
  vpc_security_group_ids = ["${aws_security_group.internal.id}"]

  tags {
    Owner = "${var.owner}"
    Name = "etcd-${count.index}"
    ansibleFilter = "${var.ansibleFilter}"
    ansibleGroup = "etcd"
    ansibleNodeName = "etcd${count.index}"
  }
}

########
## DNS
########

# Create DNS records
resource "aws_route53_record" "etcd" {
  count = "${var.node_count}"
  zone_id = "${aws_route53_zone.internal.zone_id}"
  name = "etcd${count.index}.${var.internal_dns_zone_name}"
  type = "A"
  ttl = "60"
  records = ["${ element(aws_instance.etcd.*.private_ip, count.index) }"]
}

############
# Security
############

# Securty group allowing all outbound traffic and SSH from the Bastion, and etcd ports internally
resource "aws_security_group" "internal" {
  vpc_id = "${aws_vpc.main.id}"
  name = "internal"
  description = "SSH from bastion; internal+lb etcd; all outbound"

  # Allow all outbound traffic
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow SSH from Bastion
  ingress {
    from_port = 22
    to_port = 22
    protocol = "TCP"
    security_groups = ["${aws_security_group.bastion.id}"]
  }

  # Allow etcd peer traffic between nodes
  ingress {
    from_port = "${var.etcd_peer_port}"
    to_port = "${var.etcd_peer_port}"
    protocol = "TCP"
    self = true
  }

  # Allow etcd client traffic between nodes
  ingress {
    from_port = "${var.etcd_client_port}"
    to_port = "${var.etcd_client_port}"
    protocol = "TCP"
    self = true
  }

  # Allow etcd client traffic from LB
  ingress {
    from_port = "${var.etcd_client_port}"
    to_port = "${var.etcd_client_port}"
    protocol = "TCP"
    security_groups = ["${aws_security_group.etcdlb.id}"]
  }

  # Allow internal ICMP traffic
  ingress {
    from_port = 8
    to_port = 0
    protocol = "ICMP"
    cidr_blocks = ["${var.vpc_cidr}"]
  }

  tags {
    Owner = "${var.owner}"
    Name = "internal"
  }
}

# Security Group for etcd ELB
resource "aws_security_group" "etcdlb" {
  vpc_id = "${aws_vpc.main.id}"
  name = "etcd-lb"
  description = "Inbound etcd client from world; outbound etcd client to internal"

  # etcd client from world
  ingress {
    from_port = "${var.etcd_client_port}"
    to_port = "${var.etcd_client_port}"
    protocol = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # outbound etcd client to VPC
  egress {
    from_port = "${var.etcd_client_port}"
    to_port = "${var.etcd_client_port}"
    protocol = "TCP"
    cidr_blocks = ["${var.vpc_cidr}"]
  }

  tags {
    Owner = "${var.owner}"
    Name = "etcd-lb"
  }
}

###########
## Outputs
###########

output "etcd_dns" {
  value = "${aws_elb.etcd.dns_name}"
}

output "etcd_ip" {
  value = "${join(" ", aws_instance.etcd.*.private_ip)}"
}

output "etcd_private_dns" {
  value = "${join(" ", aws_route53_record.etcd.*.name)}"
}
