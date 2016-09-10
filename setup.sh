#!/bin/bash
set -e
source default.env

if [ -z "$DIGITALOCEAN_ACCESS_TOKEN" ]; then
    echo "Error: Need to set DIGITALOCEAN_ACCESS_TOKEN"
    exit 1
fi

if [ -z $(which docker-machine) ]; then
    echo "Error: Need to install docker-machine"
    exit 1
fi

if [ -z $(which docker) ]; then
    echo "Error: Need to install docker (required for doctl)"
    exit 1
fi

dockerssh () {
  echo "docker-machine ssh $REGISTRY_DOCKER_MACHINE_NAME " $@
  docker-machine ssh $REGISTRY_DOCKER_MACHINE_NAME $@
}

echo "Creating Digital Ocean Droplet with the latest stable Docker version"
echo "It will be a $DIGITALOCEAN_DROPLET_IMAGE with $DIGITALOCEAN_DROPLET_SIZE RAM running on $DIGITALOCEAN_VOLUME_REGION"
docker-machine -D create --driver digitalocean --digitalocean-access-token $DIGITALOCEAN_ACCESS_TOKEN  --digitalocean-image "$DIGITALOCEAN_DROPLET_IMAGE" --digitalocean-region "$DIGITALOCEAN_VOLUME_REGION" --digitalocean-size "$DIGITALOCEAN_DROPLET_SIZE" registry

export DROPLET_ID=$(docker run -it --rm -e DIGITALOCEAN_ACCESS_TOKEN="$DIGITALOCEAN_ACCESS_TOKEN" francolaiuppa/doctl compute droplet list --output text --format ID,Name | grep registry | cut -f 1);
export DROPLET_IP=$(docker run -it --rm -e DIGITALOCEAN_ACCESS_TOKEN="$DIGITALOCEAN_ACCESS_TOKEN" francolaiuppa/doctl compute droplet list --output text --format PublicIPv4,Name | grep registry | cut -f1);

echo "Creating volume"
export VOLUME_ID=$(docker run -it --rm -e DIGITALOCEAN_ACCESS_TOKEN="$DIGITALOCEAN_ACCESS_TOKEN" francolaiuppa/doctl compute volume create dockervol --region $DIGITALOCEAN_VOLUME_REGION --size "$DIGITALOCEAN_VOLUME_SIZE" --format ID,Name | cut -f1 | tail -1)

echo "Attaching volume#$VOLUME_ID to droplet#$DROPLET_ID"
docker run -it --rm -e DIGITALOCEAN_ACCESS_TOKEN="$DIGITALOCEAN_ACCESS_TOKEN" francolaiuppa/doctl compute volume-action attach $VOLUME_ID $DROPLET_ID

echo "Waiting $ATTACH_VOLUME_WAIT_TIME seconds to mount volume in OS"
sleep $ATTACH_VOLUME_WAIT_TIME

echo "Stopping Docker Engine to perform configuration change"
dockerssh systemctl stop docker

echo "Formatting elastic block storage"
# format volume as Digital Ocean recommends, even though we're going to drop it later
dockerssh mkfs.ext4 -F $ELASTIC_BLOCK_STORAGE_PATH

echo "Creating mountpoint"
dockerssh mkdir -p $MNT_DOCKER_VOLUME
dockerssh mount -o discard,defaults $ELASTIC_BLOCK_STORAGE_PATH $MNT_DOCKER_VOLUME

echo "Adding to fstab"
dockerssh "echo -n \n$ELASTIC_BLOCK_STORAGE_PATH $MNT_DOCKER_VOLUME ext4 defaults,nofail,discard 0 0 >> /etc/fstab"

echo "Unmount to prepare for lvm"
dockerssh umount /dev/sda

echo "Installing lvm2 packages"
dockerssh yum install -y lvm2*

echo "Create LVM Physical Volume"
dockerssh pvcreate -f /dev/sda

echo "Create LVM Virtual Group on LVM Physical Volume"
dockerssh vgcreate docker /dev/sda

echo "Create LVM Logical Volume for docker graph data"
dockerssh lvcreate --wipesignatures y -n thinpool docker -l 95%VG

echo "Create LVM Logical Volume for docker graph metadata"
dockerssh lvcreate --wipesignatures y -n thinpoolmeta docker -l 1%VG

echo "Formatting lvm volumes to be used as a thinpool"
dockerssh lvconvert -y --zero n -c 512K --thinpool docker/thinpool --poolmetadata docker/thinpoolmeta

echo "Enabling docker lvm thin pool"
dockerssh curl -o /etc/lvm/profile/docker-thinpool.profile https://raw.githubusercontent.com/francolaiuppa/docker-registry-elastic-storage/master/docker-thinpool.profile

echo "Changing docker-thinpool to be a metadataprofile type"
dockerssh lvchange --metadataprofile docker-thinpool docker/thinpool

echo "Configure Docker daemon to run using the new docker-thinpool storage"
dockerssh curl -o /etc/docker/daemon.json https://raw.githubusercontent.com/francolaiuppa/docker-registry-elastic-storage/master/daemon.json

echo "Cleaning old docker files"
dockerssh rm -rf /var/lib/docker

echo "Reloading systemd unit file"
dockerssh systemctl daemon-reload

echo "Starting Docker Service"
dockerssh systemctl start docker

echo "Preparing data folders for Registry"
dockerssh mkdir -p /var/www/registry/data
dockerssh chmod 777 /var/www/registry/data

echo "Run Registry. TODO Add authentication"
dockerssh docker run -d --name registry -p 5000:5000 -v $(pwd)/data:/tmp/registry-dev registry:2.5.0

echo "Run Docker Registry Frontend at port 8080"
dockerssh docker run -d -e ENV_DOCKER_REGISTRY_HOST=$DROPLET_IP -e ENV_DOCKER_REGISTRY_PORT=5000 -p 8080:80 konradkleine/docker-registry-frontend:v2

# the message you were waiting for
echo "All done, please visit http://$DROPLET_IP:8080 in order to view your shiny new Private Docker Registry"
