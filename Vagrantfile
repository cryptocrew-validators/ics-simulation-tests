chain_num_validators = nil

File.foreach('.env') do |line|
  next if line.strip.start_with?('#')

  key, value = line.strip.split('=', 2)
  if key == 'NUM_VALIDATORS'
    chain_num_validators = value.to_i
    break
  end
end

if chain_num_validators.nil?
  puts "NUM_VALIDATORS not found in .env file"
  exit 1
end

Vagrant.configure("2") do |config|

  # Create the provider-chain validators
  (1..chain_num_validators).each do |i|
    config.vm.define "provider-chain-validator#{i}" do |node|
      node.vm.box = "ubuntu/jammy64" # ubuntu/focal64
      node.vm.network "private_network", ip: "192.168.33.1#{i}"
      node.vm.provider "virtualbox" do |v|
        v.memory = 4096
        v.cpus = 4
      end
      node.vm.provision "file", source: ".env", destination: "/home/vagrant/.env"
      node.vm.provision "shell", path: "setup.sh", env: {"NODE_INDEX" => i, "CHAIN_ID" => "provider-chain"}

      if i == 1
        node.vm.provision "shell", inline: <<-SHELL
          mkdir -p /home/vagrant/.hermes
          chown vagrant:vagrant /home/vagrant/.hermes
        SHELL

        node.vm.provision "file", source: "hermes_config.toml", destination: "/home/vagrant/.hermes/config.toml"
      end
    end
  end

  # Create the consumer-chain validators
  (1..chain_num_validators).each do |i|
    config.vm.define "consumer-chain-validator#{i}" do |node|
      node.vm.box = "ubuntu/jammy64" #ubuntu/focal64
      node.vm.network "private_network", ip: "192.168.34.1#{i}"
      node.vm.provider "virtualbox" do |v|
        v.memory = 4096
        v.cpus = 4
      end
      node.vm.provision "file", source: ".env", destination: "/home/vagrant/.env"
      node.vm.provision "shell", path: "setup.sh", env: {"NODE_INDEX" => i, "CHAIN_ID" => "consumer-chain"}
    end
  end
end