# Seed kullanıcılar

```bash
# Sunucu (Caddy arkasında API)
cd /var/io/io-devops
export API_URL=https://api.istanbulofset.net
export PGPASSWORD="$(grep ^POSTGRES_PASSWORD= .env | cut -d= -f2-)"
./scripts/seed-role-users.sh

# Ortak şifre
./scripts/seed-role-users.sh --password 'TestUser1a'
```

Çıktı: ekran + `seed-role-users.credentials.txt`

## Listele

```bash
cd /var/io/io-devops
./scripts/list-users.sh
./scripts/list-users.sh --seed
./scripts/list-users.sh --role Admin
```

Şifreler DB’de hash; seed şifreleri için `scripts/seed-role-users.credentials.txt`.
