chain_num_validators = nil
consumer_migration = false
consumer_migration_state_export = nil
consumer_chain_id = nil
cache_server = false
vagrant_num_cpu = nil
vagrant_memory = nil

File.foreach('.env') do |line|
  next if line.strip.start_with?('#')

  key, value = line.strip.split('=', 2)
  if key == 'NUM_VALIDATORS'
    chain_num_validators = value.to_i
  elsif key == 'CACHE_SERVER'
    cache_server = value.downcase == 'true'
  elsif key == 'VAGRANT_NUM_CPU'
    vagrant_num_cpu = value.to_i
  elsif key == 'VAGRANT_MEMORY'
    vagrant_memory = value.to_i
  elsif key == 'CONSUMER_CHAIN_ID'
    consumer_chain_id = value.downcase
  end
end

# Validate inputs
if chain_num_validators.nil?
  puts "NUM_VALIDATORS not found in .env file"
  exit 1
end

Vagrant.configure("2") do |config|

  # Create the provider-chain validators
  (1..chain_num_validators).each do |i|
    config.vm.provider "virtualbox" do |vb|
      vb.customize ["modifyvm", :id, "--audio", "none"]
    end
    config.vm.define "provider-chain-validator#{i}" do |node|
      node.vm.box = "ubuntu/jammy64" # ubuntu/focal64
      node.vm.network "private_network", type: "hostonly", ip: "192.168.33.1#{i}"
      node.vm.provider "virtualbox" do |v|
        v.memory = vagrant_memory || 2048
        v.cpus = vagrant_num_cpu || 2
      end
      node.vm.provision "file", source: ".env", destination: "/home/vagrant/.env"
      node.vm.provision "shell", path: "setup.sh", env: {"NODE_INDEX" => i, "CHAIN_ID" => "provider-chain"}

      config.vm.provision :shell, inline: <<-SHELL
        sed -ie 's/^PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config
        sed -ie 's/^#MaxAuthTries.*/MaxAuthTries 100/g' /etc/ssh/sshd_config
        service sshd reload
        echo "--> Server reporting for duty."
      SHELL
      if cache_server
        node.vm.provision "shell", inline: <<-SHELL
          echo 'Acquire::http::Proxy "http://192.168.33.1:3128";' | sudo tee /etc/apt/apt.conf.d/01proxy
          echo 'export http_proxy="http://192.168.33.1:3128"' | sudo tee -a /etc/environment
          echo 'export https_proxy="http://192.168.33.1:3128"' | sudo tee -a /etc/environment
          echo 'export no_proxy="localhost,127.0.0.1"' | sudo tee -a /etc/environment
        SHELL
      end
      
      if i == 1
        node.vm.provision "shell", inline: <<-SHELL
          mkdir -p /home/vagrant/.hermes
          chown vagrant:vagrant /home/vagrant/.hermes
        SHELL

        node.vm.provision "file", source: "config/hermes_config.toml", destination: "/home/vagrant/.hermes/config.toml"
      end
    end
  end

  # Create the consumer-chain validators
  (1..chain_num_validators).each do |i|
    config.vm.provider "virtualbox" do |vb|
      vb.customize ["modifyvm", :id, "--audio", "none"]
    end
    config.vm.define "consumer-chain-validator#{i}" do |node|
      node.vm.box = "ubuntu/jammy64" # ubuntu/focal64
      node.vm.network "private_network", type: "hostonly", ip: "192.168.33.2#{i}"
      node.vm.provider "virtualbox" do |v|
        v.memory = vagrant_memory || 2048
        v.cpus = vagrant_num_cpu || 2
      end
      node.vm.provision "file", source: ".env", destination: "/home/vagrant/.env"
      node.vm.provision "shell", path: "setup.sh", env: {"NODE_INDEX" => i, "CHAIN_ID" => consumer_chain_id}
      
      config.vm.provision :shell, inline: <<-SHELL
        sed -ie 's/^PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config
        sed -ie 's/^#MaxAuthTries.*/MaxAuthTries 100/g' /etc/ssh/sshd_config
        service sshd reload
        echo "--> Server reporting for duty."
      SHELL
      if cache_server
        node.vm.provision "shell", inline: <<-SHELL
          echo 'Acquire::http::Proxy "http://192.168.33.1:3128";' | sudo tee /etc/apt/apt.conf.d/01proxy
          echo 'export http_proxy="http://192.168.33.1:3128"' | sudo tee -a /etc/environment
          echo 'export https_proxy="http://192.168.33.1:3128"' | sudo tee -a /etc/environment
          echo 'export no_proxy="localhost,127.0.0.1"' | sudo tee -a /etc/environment
        SHELL
      end

      if consumer_migration && consumer_migration_state_export
        node.vm.provision "file", source: consumer_migration_state_export, destination: "/home/vagrant/migration_state_export.json"
      end
    end
  end
end
