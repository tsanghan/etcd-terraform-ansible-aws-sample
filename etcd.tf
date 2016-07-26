provider "aws" {
  access_key = ""
  secret_key = ""
  shared_credentials_file = "./credentials"
  region = "eu-west-1"
}

# TODO Change this hack using cidr* functions
variable vpc_base_cidr {
  default = "10.42"
}

variable keypair_name {
  description = "Name of the KeyPair used for ALL instances"
  default = "lorenzo-glf"
}

variable oc_cidr {
  description = "OC outbound external IP"
  default = "217.138.34.2/32"
}

variable etcd_ami {
  description = "Amazon Linux AMI 2016.03.3 x86_64 HVM GP2"
  default = "ami-f9dd458a"
}

variable bastion_ami {
  description = "Amazon Linux AMI 2016.03.3 x86_64 HVM GP2"
  default = "ami-f9dd458a"
}

variable "az" {
  description = "Avaiability Zones"
  default = {
    # TODO Interpolate Region name
    "0" = "eu-west-1a"
    "1" = "eu-west-1b"
    "2" = "eu-west-1c"
  }
}


# VPC
resource "aws_vpc" "main" {
  cidr_block = "${var.vpc_base_cidr}.0.0/16" # TODO Change this hack using cidr* functions

  tags {
    Name = "Lorenzo GLF"
  }
}


##############
## DMZ subnets
##############

# Public (DMZ) Subnets
resource "aws_subnet" "dmz" {
  count = 3
  vpc_id = "${aws_vpc.main.id}"
  cidr_block = "${var.vpc_base_cidr}.${100+count.index}.0/24" # TODO Change this hack using cidr* functions
  availability_zone = "${lookup(var.az, count.index)}"

  tags {
    Name = "DMZ"
    Owner = "Lorenzo"
  }
}

# Internet Gateway for DMZ Subnets
resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.main.id}"
  tags {
    Name = "DMZ"
    Owner = "Lorenzo"
  }
}

# Route Tables for DMZs, through the Internet Gateway
# TODO Any way of specifying a single route?
resource "aws_route_table" "inetgw" {
  vpc_id = "${aws_vpc.main.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.gw.id}"
  }
  tags {
    Name = "DMZ"
    Owner = "Lorenzo"
  }
}
resource "aws_route_table_association" "inetgw0" {
    count = 3
    subnet_id = "${element(aws_subnet.dmz.*.id, count.index)}"
    route_table_id = "${aws_route_table.inetgw.id}"
}

# ELB
resource "aws_elb" "etcd" {
    name = "lorenzoEtcd"
    listener {
      instance_port = 2379
      instance_protocol = "TCP"
      lb_port = 2379
      lb_protocol = "TCP"
    }
    cross_zone_load_balancing = true
    instances = ["${aws_instance.etcd.*.id}"]
    subnets = ["${aws_subnet.dmz.*.id}"]
    tags {
      Name = "etcd"
      Owner = "Lorenzo"
    }
}

##################
## Private subnets
##################


# Private (etcd) Subnets
resource "aws_subnet" "etcd" {
  count = 3
  vpc_id = "${aws_vpc.main.id}"
  cidr_block = "${var.vpc_base_cidr}.${count.index}.0/24" # TODO Change this hack using cidr* functions
  availability_zone = "${lookup(var.az, count.index)}"

  tags {
    Name = "etcd"
    Owner = "Lorenzo"
  }
}

# EIPs for NAT Gateways
resource "aws_eip" "nat" {
  count = 3
  vpc = true
  associate_with_private_ip = "${var.vpc_base_cidr}.${count.index}.1/24" # TODO Change this hack using cidr* functions
}

# NAT Gateways
resource "aws_nat_gateway" "nat" {
  count = 3
  allocation_id = "${element(aws_eip.nat.*.id, count.index)}"
  subnet_id = "${element(aws_subnet.dmz.*.id, count.index)}" # Must be in a public subnet
}

# Route Tables for Private Subnets
# TODO Any way to compact it using a count?
resource "aws_route_table" "nat0" {
  vpc_id = "${aws_vpc.main.id}"
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = "${aws_nat_gateway.nat.0.id}"
  }
  tags {
    Name = "etcd"
    Owner = "Lorenzo"
  }
}
resource "aws_route_table_association" "nat0" {
    subnet_id = "${aws_subnet.etcd.0.id}"
    route_table_id = "${aws_route_table.nat0.id}"
}

resource "aws_route_table" "nat1" {
  vpc_id = "${aws_vpc.main.id}"
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = "${aws_nat_gateway.nat.1.id}"
  }
  tags {
    Name = "etcd"
    Owner = "Lorenzo"
  }
}
resource "aws_route_table_association" "nat1" {
    subnet_id = "${aws_subnet.etcd.1.id}"
    route_table_id = "${aws_route_table.nat1.id}"
}

resource "aws_route_table" "nat2" {
  vpc_id = "${aws_vpc.main.id}"
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = "${aws_nat_gateway.nat.2.id}"
  }
  tags {
    Name = "etcd"
    Owner = "Lorenzo"
  }
}
resource "aws_route_table_association" "nat2" {
    subnet_id = "${aws_subnet.etcd.2.id}"
    route_table_id = "${aws_route_table.nat2.id}"
}


##############
## Instances
##############


# Instances for etcd
resource "aws_instance" "etcd" {
  count = 3
  ami = "${var.etcd_ami}"
  instance_type = "t2.micro"
  availability_zone = "${lookup(var.az, count.index)}"
  subnet_id = "${element(aws_subnet.etcd.*.id, count.index)}"
  key_name = "${var.keypair_name}"
  security_groups = ["${aws_security_group.internal.id}"]

  tags {
    Owner = "Lorenzo"
    Name = "etcd"
  }
}

# Securty group allowing all outbound traffic and SSH from the Bastion
resource "aws_security_group" "internal" {
  name = "internal"
  description = "Allow all outbound traffic"
  vpc_id = "${aws_vpc.main.id}"

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 22
    to_port = 22
    protocol = "TCP"
    security_groups = ["${aws_security_group.bastion.id}"] # Allow SSH from the Bastion
  }

  tags {
    Owner = "Lorenzo"
    Name = "internal"
  }
}

##########
## Bastion
##########

# EIP for Bastion
resource "aws_eip" "bastion" {
    instance = "${aws_instance.bastion.id}"
    vpc = true
}

# Bastion
resource "aws_instance" "bastion" {
  ami = "${var.bastion_ami}"
  instance_type = "t2.micro"
  availability_zone = "${var.az.0}" # AZ is arbitrary
  security_groups = ["${aws_security_group.bastion.id}"]
  subnet_id = "${aws_subnet.dmz.0.id}"
  associate_public_ip_address = true
  source_dest_check = false # TODO Is this required for tunneling SSH?
  key_name = "${var.keypair_name}"

  tags {
    Owner = "Lorenzo"
    Name = "bastion"
  }
}

# Security Group allowing incoming SSH from OC IP
resource "aws_security_group" "bastion" {
    name = "bastion"
    vpc_id = "${aws_vpc.main.id}"

    ingress {
      from_port = 22
      to_port = 22
      protocol = "TCP"
      cidr_blocks = ["${var.oc_cidr}"]
    }

    egress {
      from_port = 0
      to_port = 0
      protocol = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
    tags {
      Owner = "Lorenzo"
      Name = "bastion"
    }
}

## Outputs

output "bastion_ip" {
  value = "${aws_eip.bastion.public_ip}"
}

output "etcd_dns" {
  value = "${aws_elb.etcd.dns_name}"
}

output "etcd_ip" {
  value = "${join(",", aws_instance.etcd.*.private_ip)}"
}
