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
> Need `jq` `unzip` `awk`

In Arch Linux:
```
sudo pacman -S git jq gawk unzip

```
In Debian/Ubuntu 
```
sudo apt install git jq unzip gawk -y

```
In Windows: 
```
winget install jq -e --scope machine --source winget
winget install git -e --scope machine --source winget

```
> [!IMPORTANT]
> Windows Open Git Bash and Run Here.
> 
> The script does not check versions, if you add a minor plugin to the one already installed it will install it on top of it
> 
> Manifest.json files that have non-functional characters with .json are not detected, Example: comments.


## [AddonManager.sh 🩹 ](https://github.com/weskerty/BedrockAddonInstaller/blob/master/BedrockAddonManager.sh) 
![AddonManager](https://github.com/user-attachments/assets/c15e2d55-278b-4e5d-b70c-026fa331b33b)

> [!CAUTION]
> This script is incomplete. Using it will disable resources. Added in case anyone wants to improve it.
Missing features such as:
- [ ] Add a module with the specified version
- [ ] Add subpackages with folder_name and memory_tier
- [ ] Doesn't break the structure


### [Updater.sh](https://github.com/weskerty/BedrockAddonInstaller/blob/master/Updater.sh)
  Simply upload your packages to Github. It is not Tested.
  

## [WaterDog Update](https://github.com/weskerty/WaterdogPEUpdater)
  You use WaterDogPM and want to keep it updated.



