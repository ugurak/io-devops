# Seed kullanıcılar

```bash
# Sunucu — .env API_DOMAIN; auth rate limit 10/dk → kayıtlar arası ~7s
cd /var/io/io-devops
./scripts/seed-role-users.sh --password 'SeedUser1a'

# Sadece eksik Admin’ler (429 sonrası)
./scripts/seed-role-users.sh --password 'SeedUser1a' --roles Admin

# veya açıkça:
API_URL=https://api.istanbulofset.net ./scripts/seed-role-users.sh --password 'SeedUser1a'
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
