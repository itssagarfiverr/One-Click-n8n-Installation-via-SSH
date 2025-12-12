# 🚀 One-Click **n8n Automation Platform** Installation (Ubuntu & AlmaLinux)

Easily install **n8n (Open-Source Workflow Automation)** on your **Ubuntu** or **AlmaLinux 8/9/10** server using a single script — complete with:

- Docker & Docker Compose  
- PostgreSQL Database  
- Secure Reverse Proxy (Nginx)  
- Automatic SSL (Let's Encrypt)  
- Optional Basic Auth  
- Auto-start on reboot  

Perfect for developers, automation experts, DevOps engineers, and self-hosters!

---

## 🛠️ Features
- 🌐 Full domain support with HTTPS  
- 🐳 Installs Docker + Compose automatically  
- 🔐 n8n Basic Auth (Username + Password)  
- 🛢 PostgreSQL high-performance DB  
- 🚀 Production-grade Nginx reverse proxy  
- 🔁 Auto-renewing SSL certificates  
- 🎛 Runs n8n under system Docker engine  
- 🎯 Works on **Ubuntu** & **AlmaLinux 8/9/10**

---

## 📌 Prerequisites
> **OS Recommended:** Ubuntu 20+ or AlmaLinux 8 / 9 / 10  
> **A server/VPS with root SSH access**  
> **A domain pointing to your server’s IP**  

---

## 📥 Installation Steps

### 📝 Step 1: Connect to your server
Use SSH:

```bash
ssh root@your-server-ip
```

---

### ⚡ Step 2: Run the One-Click Installation Script

> Replace the raw link below with your GitHub raw script URL.

```bash
cd /root && \
curl -o n8n_install.sh https://raw.githubusercontent.com/itssagarfiverr/One-Click-n8n-Installation-via-SSH/refs/heads/main/n8n_install.sh && \
chmod +x n8n_install.sh && \
./n8n_install.sh && \
rm -f n8n_install.sh
```

### 📸 Step 3: Enter Basic n8n Setup Details

Once the installer starts, you will be asked for:

* 🌍 Domain
* 📧 Email (for SSL + alerts)
* 👤 n8n Username
* 🔑 n8n Password
* 🕒 Timezone (optional)

**Example Prompt Preview:**
(Replace this with a real screenshot later)

![Prompt Screenshot](https://i.ibb.co/7k7dCcy/sample.png)

---

## 🎉 Installation Complete!

After the script finishes, your n8n instance is ready.

### 🔗 **Your n8n Dashboard**

```
https://your-domain.com
```

### 👤 Login Credentials

```
Username: (your chosen username)
Password: (your chosen password)
```

### 📂 Project Directory

```
/opt/n8n
```

### 🐳 Manage Docker Stack

```bash
cd /opt/n8n
sudo docker compose ps
sudo docker compose logs -f n8n
```

---

## 📌 Example Screenshot

(Add a workflow automation dashboard screenshot later)

![n8n running](https://i.ibb.co/zV6h3g5/example.png)

---

## ⭐ Why Self-Host n8n?

* 0% usage limits
* Secure, private, self-owned automation engine
* Integrate WhatsApp, CRM, email, APIs, AI, and webhooks
* Build complex workflows without coding

---

## 💬 Connect With Me

If you found this helpful, feel free to connect on LinkedIn:

[![LinkedIn](https://upload.wikimedia.org/wikipedia/commons/0/01/LinkedIn_Logo.svg)](https://www.linkedin.com/in/sagaryadav7412/)

---

## 🙌 Support

Drop a ⭐ on GitHub if you like this tool!
More one-click installers (Docker, CRM, APIs) coming soon 🚀

```
