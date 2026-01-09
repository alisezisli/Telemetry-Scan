Vagrant.configure("2") do |config|
  # Create a Ubuntu 22.04.5 LTS (Jammy Jellyfish) VM for the environment:
  config.vm.box = "ubuntu/jammy64"
  # Make sure the sync folder exists:
  config.vm.synced_folder ".", "/vagrant"
  # Use bridged adapter so you won't have to deal with port forwarding:
  config.vm.network "public_network"
  # Use VirtualBox as provider:  
  config.vm.provider "virtualbox" do |vb|
    vb.name = "Telemetry Scan"
    vb.memory = 8192
    vb.cpus = 4
  end
  # Startup script for VM:
  config.vm.provision "shell", path: "bootstrap.sh"
end