Vagrant.configure("2") do |config|
  # Create the provider-chain validators
  (1..3).each do |i|
    config.vm.define "provider-validator#{i}" do |node|
      node.vm.box = "ubuntu/focal64"
      node.vm.network "private_network", ip: "192.168.33.1#{i}"
      node.vm.provider "virtualbox" do |v|
        v.memory = 2048
        v.cpus = 2
      end
      node.vm.provision "shell", path: "setup.sh", env: {"NODE_INDEX" => i, "CHAIN_ID" => "provider-chain"}
      node.vm.provision "file", source: ".env", destination: "/home/vagrant/.env" # Add this line
    end
  end

  # Create the consumer-chain validators
  (1..3).each do |i|
    config.vm.define "consumer-validator#{i}" do |node|
      node.vm.box = "ubuntu/focal64"
      node.vm.network "private_network", ip: "192.168.34.1#{i}"
      node.vm.provider "virtualbox" do |v|
        v.memory = 2048
        v.cpus = 2
      end
      node.vm.provision "shell", path: "setup.sh", env: {"NODE_INDEX" => i, "CHAIN_ID" => "consumer-chain"}
      node.vm.provision "file", source: ".env", destination: "/home/vagrant/.env" # Add this line
    end
  end
end