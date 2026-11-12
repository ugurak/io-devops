# GlitchTip ilk kurulum (her açılışta çalışır, var olanı korur): veritabanı, yönetici, "istanbulofset" organizasyonu,
# "API" ve "Web" projeleri. Proje anahtarları ortamdan verilen sabit değerlere ayarlanır ki DSN'ler önceden bilinsin.
# Kullanım: python /setup/provision.py (GlitchTip imajında, /code dizininde)
import os
import sys
import uuid

import psycopg

# 1) Veritabanı yoksa oluştur (paylaşılan Postgres sunucusunda ayrı veritabanı).
url = os.environ["DATABASE_URL"]
base, dbname = url.rsplit("/", 1)
with psycopg.connect(f"{base}/postgres", autocommit=True) as conn:
    if not conn.execute("select 1 from pg_database where datname = %s", (dbname,)).fetchone():
        conn.execute(f'create database "{dbname}"')
        print(f"veritabanı oluşturuldu: {dbname}")

sys.path.insert(0, "/code")
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "glitchtip.settings")
import django  # noqa: E402

django.setup()
from django.conf import settings  # noqa: E402
from django.contrib.auth import get_user_model  # noqa: E402
from django.core.management import call_command  # noqa: E402

call_command("migrate", no_input=True, skip_checks=True, verbosity=0)

from apps.organizations_ext.models import Organization, OrganizationOwner, OrganizationUser, OrganizationUserRole  # noqa: E402
from apps.projects.models import Project, ProjectKey  # noqa: E402
from apps.teams.models import Team  # noqa: E402

email = os.environ["GLITCHTIP_ADMIN_EMAIL"]
User = get_user_model()
user = User.objects.filter(email=email).first() or User.objects.create_superuser(email=email, password=os.environ["GLITCHTIP_ADMIN_PASSWORD"])

# GlitchTip slug'ı addan kendisi üretir ("istanbul-ofset"); slug ile aramak her açılışta yeni organizasyon açıyordu.
# Ada göre en eski organizasyon kullanılır (DSN'lerdeki proje no'ları /1 ve /2 ona ait); kurulumun önceki
# sürümlerinin açtığı kopyalar silinir.
ORG_NAME = "İstanbul Ofset"
org = Organization.objects.filter(name=ORG_NAME).order_by("pk").first() or Organization.objects.create(name=ORG_NAME)
duplicates = Organization.objects.filter(name=ORG_NAME).exclude(pk=org.pk)
if duplicates.exists():
    print(f"kopya organizasyonlar siliniyor: {list(duplicates.values_list('pk', flat=True))}")
    duplicates.delete()
member, _ = OrganizationUser.objects.get_or_create(organization=org, user=user, defaults={"role": OrganizationUserRole.OWNER})
if not OrganizationOwner.objects.filter(organization=org).exists():
    OrganizationOwner.objects.create(organization=org, organization_user=member)
team, _ = Team.objects.get_or_create(organization=org, slug="istanbulofset")
team.members.add(member)

domain = settings.GLITCHTIP_URL.geturl() if hasattr(settings, "GLITCHTIP_URL") else os.environ.get("GLITCHTIP_DOMAIN", "")
scheme, host = domain.split("://", 1)
for name, platform, env_key in [("API", "csharp-aspnetcore", "GLITCHTIP_API_KEY"), ("Web", "javascript-nextjs", "GLITCHTIP_WEB_KEY")]:
    project = Project.objects.filter(organization=org, name=name).first() or Project.objects.create(organization=org, name=name, platform=platform)
    team.projects.add(project)
    wanted = (os.environ.get(env_key) or "").strip().lower()
    # İstenen anahtar zaten varsa onu kullan (projeye ait değilse bu projeye taşı); yoksa projenin ilk anahtarına yaz.
    # Böylece kurulum her açılışta tekrar çalışsa da "public_key already exists" hatası vermez.
    key = ProjectKey.objects.filter(public_key=uuid.UUID(wanted)).first() if wanted else None
    if key and key.project_id != project.id:
        ProjectKey.objects.filter(pk=key.pk).update(project=project)
        key.refresh_from_db()
    if key is None:
        key = ProjectKey.objects.filter(project=project).order_by("pk").first() or ProjectKey.objects.create(project=project)
        if wanted and str(key.public_key) != wanted:
            ProjectKey.objects.filter(pk=key.pk).update(public_key=uuid.UUID(wanted))
            key.refresh_from_db()
    print(f"{name} DSN: {scheme}://{key.public_key}@{host.rstrip('/')}/{project.id}")
