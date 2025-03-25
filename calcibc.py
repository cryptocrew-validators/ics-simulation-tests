import hashlib

def calculate_ibc_denom(path, base_denom):
    combined = f"{path}/{base_denom}"
    hash_result = hashlib.sha256(combined.encode()).hexdigest()
    return f"ibc/{hash_result}"

# Example usage
path = "transfer/channel-1"
base_denom = "uelys"
ibc_denom = calculate_ibc_denom(path, base_denom)
print(ibc_denom)
