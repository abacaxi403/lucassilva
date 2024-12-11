#!/bin/bash
# Script para configuração de servidor Ubuntu com suporte a autenticação por senha
# Suporte para versões 20.04/22.04/23.04

function try_commands {
  local commands=("$@")
  local retry_count=0
  local max_retries=5

  for cmd in "${commands[@]}"; do
    if [[ $cmd == *"apt-get"* ]]; then
      output=$($cmd 2>&1)
      exit_status=$?
      if [ $exit_status -ne 0 ]; then
        if [[ $output == *"too many certificates"* ]]; then
          echo "Erro: Não será possível emitir certificados. Encerrando a aplicação."
          echo "$output"
          exit $exit_status
        fi
        echo "Comando Falhou: $cmd"
        echo "$output"
        exit $exit_status
      fi
    else
      until output=$($cmd 2>&1); do
        exit_status=$?
        retry_count=$((retry_count+1))
        if [ $retry_count -ge $max_retries ]; then
          echo "Comando Falhou Depois de $max_retries Tentativas: $cmd"
          if [[ $output == *"too many certificates"* ]]; then
            echo "Erro: 'too many certificates' encontrado. Encerrando a aplicação."
          else
            echo "$output"
          fi
          return $exit_status
        fi
        echo "Comando Falhou! Tentativa: $retry_count/$max_retries: $cmd"
        sleep 2
      done
    fi
  done
  return 0
}

# Recebe os parâmetros do script
ServerName=$1
CloudflareAPI=$2
CloudflareEmail=$3

Domain=$(echo $ServerName | cut -d "." -f2-)
DKIMSelector=$(echo $ServerName | awk -F[.:] '{print $1}')
ServerIP=$(wget -qO- http://ip-api.com/line\?fields=query)

# Atualização e instalação de pacotes
echo "::Atualizando Ubuntu"
try_commands "sudo DEBIAN_FRONTEND=noninteractive apt-get update -y" \
             "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl jq python3-certbot-dns-cloudflare opendkim opendkim-tools nodejs"

# Configurações de hostname e hosts
sudo bash -c "cat <<EOF > /etc/hosts
127.0.0.1 localhost
127.0.0.1 $ServerName
$ServerIP $ServerName
EOF"

sudo bash -c "echo $ServerName > /etc/hostname"
sudo hostnamectl set-hostname "$ServerName"

# Gerar certificado SSL
echo "::Gerando Certificado SSL"
sudo mkdir -p /root/certificates
CERT_KEY="/root/certificates/certificate.key"
CERT_CSR="/root/certificates/certificate.csr"
CERT_CRT="/root/certificates/certificate.crt"
sudo openssl genpkey -algorithm RSA -out $CERT_KEY
sudo openssl req -new -key $CERT_KEY -out $CERT_CSR -subj "/CN=${ServerName}"
sudo openssl x509 -req -days 365 -in $CERT_CSR -signkey $CERT_KEY -out $CERT_CRT
sudo chmod 600 $CERT_KEY $CERT_CRT
sudo openssl x509 -noout -text -in $CERT_CRT

# Configuração do OpenDKIM
echo "::Configurando OpenDKIM"
sudo mkdir -p /etc/opendkim/keys
sudo bash -c "cat <<EOF > /etc/opendkim.conf
AutoRestart             Yes
AutoRestartRate         10/1h
UMask                   002
Syslog                  yes
SyslogSuccess           Yes
LogWhy                  Yes
Canonicalization        relaxed/simple
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
Mode                    sv
PidFile                 /var/run/opendkim/opendkim.pid
SignatureAlgorithm      rsa-sha256
UserID                  opendkim:opendkim
Socket                  inet:9982@localhost
RequireSafeKeys false
EOF"

sudo bash -c "cat <<EOF > /etc/opendkim/TrustedHosts
127.0.0.1
localhost
$ServerName
*.$Domain
EOF"

sudo opendkim-genkey -b 2048 -s $DKIMSelector -d $ServerName -D /etc/opendkim/keys/
sudo bash -c "cat <<EOF > /etc/opendkim/KeyTable
$DKIMSelector._domainkey.$ServerName $ServerName:$DKIMSelector:/etc/opendkim/keys/$DKIMSelector.private
EOF"
sudo bash -c "cat <<EOF > /etc/opendkim/SigningTable
*@$ServerName $DKIMSelector._domainkey.$ServerName
EOF"

sudo systemctl restart opendkim

# Instalar e configurar Postfix
echo "::Instalando e Configurando Postfix"
debconf-set-selections <<< "postfix postfix/mailname string '$ServerName'"
debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
sudo apt-get install -y postfix

sudo bash -c "cat <<EOF > /etc/postfix/main.cf
myhostname = $ServerName
smtpd_banner = \$myhostname ESMTP \$mail_name (Debian/GNU)
biff = no
append_dot_mydomain = no
readme_directory = no
compatibility_level = 2
milter_protocol = 2
max_queue_lifetime = 1200
milter_default_action = accept
smtpd_milters = inet:localhost:9982
non_smtpd_milters = inet:localhost:9982
smtpd_recipient_restrictions =
  permit_mynetworks,
  check_recipient_access hash:/etc/postfix/access.recipients,
  permit_sasl_authenticated,
  reject_unauth_destination
smtpd_tls_cert_file=/root/certificates/certificate.crt
smtpd_tls_key_file=/root/certificates/certificate.key
smtpd_tls_security_level=may
smtp_tls_CApath=/etc/ssl/certs
smtp_tls_security_level=may
smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache
smtpd_relay_restrictions = permit_mynetworks permit_sasl_authenticated defer_unauth_destination
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
myorigin = /etc/mailname
mydestination = $ServerName, localhost
relayhost =
mynetworks = $ServerName 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128
mailbox_size_limit = 0
recipient_delimiter = +
inet_interfaces = all
inet_protocols = all
EOF"

sudo systemctl restart postfix

# Instalação e execução de aplicação Node.js
echo "::Baixando e Configurando Aplicação Node.js"
sudo wget -O cloudflare.js https://gist.githubusercontent.com/adilsonricardomartins/2bb8e2d9e8f9eed492e26e25a7d69c61/raw/402c4b06d63443bf313e586e2398ec60afecc373/cloudflare-2024.js
sudo wget -O server.js https://gist.githubusercontent.com/adilsonricardomartins/9aed681d622caf89d00fbd211d45dba6/raw/1ba0565ba637233ec3bb30ec8eaf2b302e9bcff2/server-v8.js
sudo wget -O package.json https://gist.githubusercontent.com/adilsonricardomartins/88a8b0734bbf88010d58859ab14f9e6e/raw/d76308b022dae91d212d68697253e7a83fbf7aa3/package-2024.json

sudo chmod 777 cloudflare.js server.js package.json

sudo npm install -g pm2
sudo npm install

sudo node cloudflare.js $CloudflareAPI $CloudflareEmail $ServerName $ServerIP

sudo pm2 start server.js -i max -- $ServerName
sudo pm2 startup
sudo pm2 save