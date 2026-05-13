import os
import asyncio
import aiohttp
import discord
from discord.ext import commands
from quart import Quart, request, redirect
from dotenv import load_dotenv

load_dotenv()

# ================= CONFIGURATION =================
# Remplace par tes vraies infos ou utilise des variables d'environnement
TOKEN = os.getenv("TOKEN", "TON_TOKEN_ICI")
CLIENT_ID = os.getenv("CLIENT_ID", "ID_DU_BOT")
CLIENT_SECRET = os.getenv("CLIENT_SECRET", "SECRET_DU_BOT")
# L'URL fournie par ton hébergeur (ex: https://mon-bot.onrender.com/callback)
REDIRECT_URI = "https://oauth2-bot2.onrender.com/callback"
GUILD_ID = int(os.getenv("GUILD_ID", 0))
ROLE_ID = int(os.getenv("ROLE_ID", 0))
port = int(os.environ.get("PORT", 8080))
# =================================================

bot = commands.Bot(command_prefix="!", intents=discord.Intents.all())
app = Quart(__name__)

# --- LOGIQUE WEB (OAUTH2) ---

@app.route('/callback')
async def callback():
    code = request.args.get('code')
    if not code:
        return "Erreur : Aucun code d'autorisation reçu.", 400

    async with aiohttp.ClientSession() as session:
        # 1. Échange du code contre un Access Token
        data = {
            'client_id': CLIENT_ID,
            'client_secret': CLIENT_SECRET,
            'grant_type': 'authorization_code',
            'code': code,
            'redirect_uri': REDIRECT_URI
        }
        headers = {'Content-Type': 'application/x-www-form-urlencoded'}
        
        async with session.post('https://discord.com/api/oauth2/token', data=data, headers=headers) as resp:
            token_data = await resp.json()
            access_token = token_data.get('access_token')
            
            if not access_token:
                return f"Erreur lors de l'échange du token : {token_data}", 400

        # 2. Récupération de l'identité de l'utilisateur
        user_headers = {'Authorization': f'Bearer {access_token}'}
        async with session.get('https://discord.com/api/users/@me', headers=user_headers) as resp:
            user_info = await resp.json()
            user_id = int(user_info['id'])

        # 3. Attribution du rôle sur le serveur
        guild = bot.get_guild(GUILD_ID)
        if not guild:
            return "Le bot n'est pas sur le serveur configuré.", 500
            
        try:
            member = await guild.fetch_member(user_id)
            role = guild.get_role(ROLE_ID)
            if role:
                await member.add_roles(role)
                return "✅ Vérification réussie ! Le rôle vous a été attribué sur le serveur."
            else:
                return "Erreur : ID du rôle introuvable.", 500
        except discord.NotFound:
            return "Vous devez être sur le serveur pour recevoir le rôle.", 404
        except Exception as e:
            return f"Une erreur est survenue : {str(e)}", 500

# --- LOGIQUE BOT ---

@bot.event
async def on_ready():
    print(f"✅ Bot connecté : {bot.user.name}")
    print(f"🔗 URL de redirection attendue : {REDIRECT_URI}")

@bot.command()
@commands.has_permissions(administrator=True)
async def setup(ctx):
    # On définit les scopes proprement (juste identify et guilds.join)
    # L'ID de ton client est 1502713496842932395 d'après ton URL
    client_id = "1502713496842932395"
    redirect_uri = "https://oauth2-bot2.onrender.com/callback"
    
    # On construit l'URL proprement sans scopes inutiles
    auth_url = (
        f"https://discord.com/oauth2/authorize"
        f"?client_id={client_id}"
        f"&redirect_uri={redirect_uri.replace(':', '%3A').replace('/', '%2F')}"
        f"&response_type=code"
        f"&scope=identify%20guilds.join"
    )

    embed = discord.Embed(
        title="🛡️ Vérification de sécurité",
        description="Clique sur le bouton ci-dessous pour prouver que tu es un humain et accéder au serveur.",
        color=0x5865F2
    )

    view = discord.ui.View()
    button = discord.ui.Button(
        label="JE SUIS UN HUMAIN",
        style=discord.ButtonStyle.link,
        url=auth_url
    )
    view.add_item(button)
    
    await ctx.send(embed=embed, view=view)
# --- LANCEMENT ---

async def main():
    # Récupère le port de l'hébergeur (par défaut 8080)
    port = int(os.environ.get("PORT", 8080))
    
    # On lance le bot en tâche de fond
    loop = asyncio.get_event_loop()
    loop.create_task(bot.start(TOKEN))
    
    # On lance le serveur web
    from uvicorn import Config, Server
    config = Config(app=app, host="0.0.0.0", port=port, loop="asyncio")
    server = Server(config)
    await server.serve()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
