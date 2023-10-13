echo "Cleaning up..."
vagrant destroy -f
rm .provisioned || true
rm files/generated/* || true
rm files/logs/* || true