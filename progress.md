# Progress

## Status
In Progress — SPanel and NPanel changes complete, proxyInstall.sh and unlockCheck.sh pending

## Tasks
- [x] SPanel V2ApiController.php — added unlockCheck() method
- [x] SPanel NodeApiService.php — removed unlock from registerNode(), added updateUnlock()
- [x] SPanel config/routes.php — added POST /node/unlock_check route
- [x] NPanel NodeApiController.php — removed unlock from register(), added unlockCheck()
- [x] NPanel routes/api.php — added unlock_check route
- [ ] proxyInstall.sh — remove RunMediaUnlockCheck/GetMediaUnlockInfo, add Step4_5_LaunchUnlockCheck
- [ ] Create unlockCheck.sh

## Files Changed
- /var/www/SPanel/app/Controllers/V2ApiController.php
- /var/www/SPanel/app/Services/NodeApiService.php
- /var/www/SPanel/config/routes.php
- /var/www/NPanel/app/Http/Controllers/Api/NodeApiController.php
- /var/www/NPanel/routes/api.php

## Notes
- PHP CLI not available in this env; validated via brace balance + grep
- NPanel register() confirmed clean of unlock code (node_unlock at L194 is in unlockCheck(), L635 is in resetNodeToDefaults())
