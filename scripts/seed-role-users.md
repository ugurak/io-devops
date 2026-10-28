# Seed kullanıcılar

```bash
# Sunucu — .env içindeki API_DOMAIN / POSTGRES_PASSWORD otomatik okunur
cd /var/io/io-devops
./scripts/seed-role-users.sh --password 'SeedUser1a'

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
