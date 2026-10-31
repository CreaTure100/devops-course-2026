# Конфигурация виртуальной машины devops-vm

## 1. Параметры машины
- Гипервизор: VirtualBox 7.x, гостевая ОС Ubuntu Server 24.04 LTS (64-bit)
- Оперативная память: 2048 МБ
- Процессор: 2 ядра
- Диск: 25 ГБ, динамически расширяемый
- Имя узла: devops-vm (FQDN: devops-vm.devops.local)

## 2. Сетевые интерфейсы
| Адаптер | Тип | Интерфейс в ВМ | Адрес | Назначение |
|---|---|---|---|---|
| 1 | NAT | enp0s3 | 10.0.2.15/24 | выход в интернет, доступ к репозиториям пакетов |
| 2 | Host-only | enp0s8 | 192.168.56.101/24 | прямой доступ с хоста (SSH, веб-сервер в работе № 6) |

## 3. Правило проброса портов
Адаптер 1 (NAT), правило `ssh`: TCP, адрес хоста 127.0.0.1, порт хоста 2222,
адрес гостя не заполняется, порт гостя 2222 (изначально 22, изменён после смены порта sshd).

## 4. Учётные записи
| Имя | Группы | Аутентификация | Примечание |
|---|---|---|---|
| student | student, sudo | пароль, только консоль ВМ | создан установщиком, по SSH не допущен (AllowUsers) |
| devops | devops, sudo | ключ ed25519 по SSH | основная рабочая учётка |

Создание:
    sudo adduser devops
    sudo usermod -aG sudo devops

Ключ создаётся на хосте и копируется на сервер:
    ssh-keygen -t ed25519 -C "devops-vm-key" -f ~/.ssh/devops_vm
    ssh-copy-id -i ~/.ssh/devops_vm.pub -p 2222 devops@127.0.0.1
Права: ~/.ssh — 700, ~/.ssh/authorized_keys — 600.
Клиентский ~/.ssh/config на хосте: блоки Host devops и Host devops.local
(Port 2222, User devops, IdentityFile ~/.ssh/devops_vm, IdentitiesOnly yes).

## 5. Служба SSH
Файл: /etc/ssh/sshd_config.d/99-hardening.conf (основной sshd_config не изменялся,
резервная копия: /etc/ssh/sshd_config.backup).

Содержимое:
    Port 2222
    PermitRootLogin no
    PasswordAuthentication no
    PubkeyAuthentication yes
    PermitEmptyPasswords no
    MaxAuthTries 3
    LoginGraceTime 30
    AllowUsers devops
    X11Forwarding no
    ClientAliveInterval 300
    ClientAliveCountMax 2

Дополнительно:
- В /etc/ssh/sshd_config.d/50-cloud-init.conf строка `PasswordAuthentication yes`
  закомментирована (иначе она перекрывает 99-hardening.conf).
- Отключена сокет-активация, иначе порт остаётся 22:
      sudo systemctl disable --now ssh.socket
      sudo systemctl enable --now ssh.service
      sudo systemctl restart ssh
- Проверка: sudo sshd -t; sudo sshd -T | grep -Ei "^(port|passwordauthentication)";
  sudo ss -tlnp | grep sshd (ожидается 0.0.0.0:2222).

## 6. Правила межсетевого экрана (UFW)
Политики: deny incoming, allow outgoing. Логирование: medium.

Команды (порядок важен: правило для SSH создаётся до enable):
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw limit 2222/tcp comment 'SSH rate-limited'
    sudo ufw allow 80/tcp comment 'HTTP'
    sudo ufw allow 443/tcp comment 'HTTPS'
    sudo ufw logging medium
    sudo ufw --force enable

| Порт | Действие | Назначение |
|---|---|---|
| 2222/tcp | LIMIT | SSH с ограничением частоты (6 соединений за 30 с) |
| 80/tcp | ALLOW | HTTP (Nginx, работа № 6) |
| 443/tcp | ALLOW | HTTPS |

Правило для порта 22 не создавалось: `ufw allow ssh` открыл бы порт 22 по /etc/services.

## 7. Локальное имя
На хосте в hosts: `192.168.56.101 devops.local`.
В ВМ: `sudo hostnamectl set-hostname devops-vm`, в /etc/hosts строка
`127.0.1.1 devops-vm.devops.local devops-vm`; проверка: `hostname -f`.

## 8. Снимки состояния
| Имя | Момент создания | Состояние |
|---|---|---|
| 01-clean-install | 29.10.26 | чистая установка, обновлённая система |
| 02-keys-configured | 30.10.26 | пользователь devops, вход по ключу |
| 03-ssh-hardened | 30.10.26 | SSH усилен, порт 2222 |

## 9. Веб-сервер

- Пакет: `nginx` (установка: `sudo apt update && sudo apt install -y nginx`).
- Конфигурация ресурса: `/etc/nginx/sites-available/devops-site`, включена символической
  ссылкой в `/etc/nginx/sites-enabled/`; стандартный ресурс отключён (удалена ссылка
  `/etc/nginx/sites-enabled/default`, файл `sites-available/default` сохранён).
- Блок 1: `listen 80`, `server_name devops.local`, `return 301 https://$host$request_uri`.
- Блок 2: `listen 443 ssl` (и IPv6), `ssl_protocols TLSv1.2 TLSv1.3`, `root /var/www/devops-site`,
  `index index.html`, `error_page 404 /404.html`, журналы `/var/log/nginx/devops-site.access.log`
  и `/var/log/nginx/devops-site.error.log`.
- Каталог ресурса: `/var/www/devops-site`, владелец `devops:devops`, права 755 для каталогов
  и 644 для файлов.
- Сертификат: `/etc/ssl/certs/devops.crt` (владелец root, права 644).
- Закрытый ключ: `/etc/ssl/private/devops.key` (владелец root, права 600).
- Формирование сертификата (самоподписанный, срок 365 дней, SAN `devops.local`):
  `sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/devops.key
  -out /etc/ssl/certs/devops.crt -subj "/CN=devops.local" -addext "subjectAltName=DNS:devops.local"`.
- Применение конфигурации: `sudo nginx -t && sudo systemctl reload nginx` (не `restart`).
- Доставка содержимого: `scripts/deploy.sh` (rsync с `--delete --chmod=D755,F644`).