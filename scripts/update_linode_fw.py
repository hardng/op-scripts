
import requests
import json
import sys

# ================= 配置区域 =================
LINODE_TOKEN = "83578b9196594ef47a7f3d649e51fccef2bedc2ee9b0fcc481ebd77f64e3ab4f"
FIREWALL_LABEL = "rpc-infra"  # 将会自动根据 Label 查找 ID
ALLOWED_PORTS = "80,443"
# ===========================================

# 经过修正的 GitHub/Azure IP 列表
GITHUB_IPS = [
    "20.26.156.215/32",
    "4.208.26.197/32",
    "4.225.11.194/32",
    "20.217.135.5/32",
    "20.199.39.232/32",
    "20.29.134.23/32",
    "20.233.83.145/32",
    "20.175.192.147/32",
    "20.200.245.247/32",
    "20.27.177.113/32",
    "20.207.73.82/32",
    "4.228.31.150/32",
    "4.237.22.38/32",
    "20.87.245.0/32",
    "20.205.243.166/32",
    "20.201.28.151/32",
    "20.26.156.210/32",
    "4.208.26.200/32",
    "4.225.11.201/32",
    "20.217.135.0/32",
    "20.199.39.228/32",
    "20.29.134.17/32",
    "20.233.83.146/32",
    "20.175.192.149/32",
    "20.200.245.245/32",
    "20.27.177.116/32",
    "20.207.73.85/32",
    "4.228.31.149/32",
    "4.237.22.34/32",
    "20.87.245.6/32",
    "20.205.243.168/32",
    "20.201.28.148/32",
    "143.55.64.0/20",
    "140.82.112.0/20",
    "185.199.108.0/22",
    "192.30.252.0/22"
]

HEADERS = {
    "Authorization": f"Bearer {LINODE_TOKEN}",
    "Content-Type": "application/json"
}

def get_firewall_id_by_label(label):
    print(f"Searching for Firewall with label: {label}...")
    url = "https://api.linode.com/v4/networking/firewalls"
    page = 1
    while True:
        resp = requests.get(f"{url}?page={page}&page_size=100", headers=HEADERS)
        if resp.status_code != 200:
            print(f"Error listing firewalls: {resp.text}")
            sys.exit(1)
        
        data = resp.json()
        for fw in data.get('data', []):
            if fw['label'] == label:
                print(f"Found Firewall ID: {fw['id']}")
                return fw['id']
        
        if page >= data.get('pages', 1):
            break
        page += 1
    
    print(f"Error: Firewall with label '{label}' not found.")
    sys.exit(1)

def get_current_rules(fw_id):
    print(f"Fetching rules for Firewall ID: {fw_id}...")
    url = f"https://api.linode.com/v4/networking/firewalls/{fw_id}/rules"
    resp = requests.get(url, headers=HEADERS)
    if resp.status_code != 200:
        print(f"Error fetching rules: {resp.text}")
        sys.exit(1)
    return resp.json()

def update_firewall_rules(fw_id, inbound_rules, outbound_rules):
    print("Pushing updated rules to Linode...")
    url = f"https://api.linode.com/v4/networking/firewalls/{fw_id}/rules"
    payload = {
        "inbound": inbound_rules,
        "outbound": outbound_rules
    }
    
    resp = requests.put(url, headers=HEADERS, json=payload)
    if resp.status_code == 200:
        print("Success! Firewall rules updated successfully.")
    else:
        print(f"Failed to update rules: {resp.text}")
        sys.exit(1)

def main():
    fw_id = get_firewall_id_by_label(FIREWALL_LABEL)
    current_rules = get_current_rules(fw_id)
    
    # 过滤掉旧的同名规则
    inbound = current_rules.get('inbound', [])
    outbound = current_rules.get('outbound', [])
    
    print(f"Original inbound rules: {len(inbound)}")
    print(f"Original outbound rules: {len(outbound)}")

    # 1. 清理 Inbound (如果之前误加过，把它删掉)
    inbound = [r for r in inbound if r.get('label') != "allow-github-actions"]

    # 2. 修改 Outbound
    # Remove existing rules with our label if they exist
    outbound = [r for r in outbound if r.get('label') != "allow-github-actions"]
    
    # 构造新的 GitHub 规则 (Outbound)
    new_rule = {
        "label": "allow-github-actions",
        "action": "ACCEPT",
        "protocol": "TCP",
        "ports": ALLOWED_PORTS,
        "addresses": {
            "ipv4": GITHUB_IPS
        }
    }
    
    outbound.append(new_rule)
    
    print(f"Final inbound rules: {len(inbound)}")
    print(f"Final outbound rules: {len(outbound)}")
    print(f"Adding {len(GITHUB_IPS)} IPs to Outbound whitelist.")

    update_firewall_rules(fw_id, inbound, outbound)

if __name__ == "__main__":
    main()
