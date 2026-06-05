# Update AddOns Minecraft
Windows & Linux ([I use Bedrock Server on ArchLinux thanks to this Package](https://aur.archlinux.org/packages/minecraft-bedrock-server))


## [AddonInstall.sh](https://github.com/weskerty/BedrockAddonInstaller/blob/master/BedrockAddonInstall.sh)
Adjust the Script for Minecraft location and where downloaded addons can be found. Run Script.

```
MinecraftPath="/opt/minecraft-bedrock-server" 
AddOnsPath="Descargas/AddOns"
```

![AddOnInstaller](https://github.com/user-attachments/assets/b48eb104-8e16-43f8-8fa4-1285d37dc2cf)

> [!IMPORTANT]
> Need `nodejs`

In Arch Linux:
```
sudo pacman -S git nodejs npm unzip --noconfirm

git clone https://github.com/weskerty/BedrockAddonInstaller.git && cd BedrockAddonInstaller && npm install && npm start 

```
In Debian/Ubuntu 
```
sudo apt install git nodejs -y

git clone https://github.com/weskerty/BedrockAddonInstaller.git && cd BedrockAddonInstaller && npm install && npm start 

```
In Windows: 
```
winget install nodejs -e --scope machine --source winget
winget install git -e --scope machine --source winget

git clone https://github.com/weskerty/BedrockAddonInstaller.git && cd BedrockAddonInstaller && npm install && npm start 

```

> [!CAUTION]
> This script is incomplete. 


# Utils

## [WaterDog Proxy Updater](https://github.com/weskerty/WaterdogPEUpdater)
  You use WaterDogPM and want to keep it updated. https://waterdog.dev/

## [Server Version and E-ARM](https://github.com/itzg/docker-minecraft-bedrock-server)

# Server
## [Arch Linux](https://aur.archlinux.org/packages/minecraft-bedrock-server)

```
yay -S minecraft-bedrock-server

```

## [Ubuntu](https://github.com/TheRemote/MinecraftBedrockServer)
