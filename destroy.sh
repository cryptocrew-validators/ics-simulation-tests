echo "Cleaning up..."
vagrant destroy -f
rm .provisioned || true
rm prop.json || true
rm raw_genesis.json || true
rm final_genesis.json || true
rm result.log || true