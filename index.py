import os
import asyncio
import aiohttp
import discord
import json
from discord.ext import commands
from quart import Quart, request
from dotenv import load_dotenv

load_dotenv()

# --- CONFIGURATION ---
TOKEN = os.getenv("TOKEN")
CLIENT_ID = os.getenv("CLIENT_ID")
CLIENT_SECRET = os.getenv("CLIENT_SECRET")
REDIRECT_URI = "https://oauth2-bot2.onrender.com/callback"
GUILD_ID = int(os.getenv("GUILD_ID", 0))
ROLE_ID = int(os.getenv("ROLE_ID", 0))
DB_FILE = "users.json"

# --- INITIALISATION DB ---
if not os.path.exists(DB_FILE):
    with open(DB_FILE, "w") as f:
        json.dump({}, f)

def save_user(user_id, access_token):
    with open(DB_FILE, "r") as f:
        data = json.load(f)
    data[str(user_id)] = access_token
    with open(DB_FILE, "w") as f:
        json.dump(data, f)

# --- BOT & APP ---
bot = commands.Bot(command_prefix="!", intents=discord.Intents.all())
app = Quart(__name__)

@app.route('/callback')
async def callback():
    code = request.args.get('code')
    if not code: return "Code manquant", 400

    async with aiohttp.ClientSession() as session:
        # Échange du token
        data = {
            'client_id': CLIENT_ID, 'client_secret': CLIENT_SECRET,
            'grant_type': 'authorization_code', 'code': code, 'redirect_uri': REDIRECT_URI
        }
        async with session.post('https://discord.com/api/oauth2/token', data=data) as resp:
            token_data = await resp.json()
            access_token = token_data.get('access_token')

        if access_token:
            # Récupérer l'ID user
            headers = {'Authorization': f'Bearer {access_token}'}
            async with session.get('https://discord.com/api/users/@me', headers=headers) as resp:
                user_info = await resp.json()
                user_id = user_info['id']
                
                # SAUVEGARDE DU TOKEN POUR PLUS TARD
                save_user(user_id, access_token)

            # Donner le rôle immédiat
            guild = bot.get_guild(GUILD_ID)
            member = await guild.fetch_member(int(user_id))
            if member:
                await member.add_roles(guild.get_role(ROLE_ID))
            
            return "✅ Vérifié ! Tes données sont enregistrées."
    return "Erreur lors de la vérification", 500

# --- COMMANDES ---

@bot.command()
@commands.has_permissions(administrator=True)
async def setup(ctx):
    auth_url = f"https://discord.com/api/oauth2/authorize?client_id={CLIENT_ID}&redirect_uri={REDIRECT_URI.replace(':', '%3A').replace('/', '%2F')}&response_type=code&scope=identify%20guilds.join"
    view = discord.ui.View()
    view.add_item(discord.ui.Button(label="JE SUIS UN HUMAIN", style=discord.ButtonStyle.link, url=auth_url))
    await ctx.send(embed=discord.Embed(title="Vérification", description="Cliquez ici"), view=view)

@bot.command()
@commands.has_permissions(administrator=True)
async def join(ctx):
    """Fait rejoindre tous les utilisateurs enregistrés au serveur actuel"""
    with open(DB_FILE, "r") as f:
        users = json.load(f)
    
    await ctx.send(f"🔄 Tentative de faire rejoindre {len(users)} utilisateurs...")
    
    count = 0
    async with aiohttp.ClientSession() as session:
        for user_id, token in users.items():
            url = f"https://discord.com/api/guilds/{ctx.guild.id}/members/{user_id}"
            headers = {"Authorization": f"Bot {TOKEN}", "Content-Type": "application/json"}
            data = {"access_token": token}
            
            async with session.put(url, headers=headers, json=data) as resp:
                if resp.status in [201, 204]:
                    count += 1
                # On ajoute un petit délai pour éviter de se faire ban par Discord (Rate Limit)
                await asyncio.sleep(0.5)
    
    await ctx.send(f"✅ Terminé ! {count} utilisateurs ont rejoint le serveur.")

# --- RUN ---
async def main():
    port = int(os.environ.get("PORT", 8080))
    loop = asyncio.get_event_loop()
    loop.create_task(bot.start(TOKEN))
    from uvicorn import Config, Server
    config = Config(app=app, host="0.0.0.0", port=port, loop="asyncio")
    await Server(config).serve()

if __name__ == "__main__":
    asyncio.run(main())
