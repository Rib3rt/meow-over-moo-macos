# Steam Backend Setup Checklist

## 1. Real App

- [ ] Use the real Steam app with AppID `1573941`
- [ ] Confirm the app has the correct Windows test branch
- [ ] Confirm Steam Overlay works in the real app build

## 2. Achievements

Create these in `Steamworks > Stats & Achievements > Achievements`.

### Required fields for each achievement

- [ ] API Name
- [ ] Display Name
- [ ] Description
- [ ] Hidden = No
- [ ] Locked icon
- [ ] Unlocked icon

### Achievement list

- [ ] `ACH_FIRST_ORDERS`
  - Display: `First Orders`
  - Description: `Start your first match.`

- [ ] `ACH_BEAT_BURT`
  - Display: `Burt, Beaten`
  - Description: `Defeat Burt.`

- [ ] `ACH_BEAT_BURNS`
  - Display: `Burns Down`
  - Description: `Defeat Burns.`

- [ ] `ACH_BEAT_MARGE`
  - Display: `Marge Overruled`
  - Description: `Defeat Marge.`

- [ ] `ACH_BEAT_HOMER`
  - Display: `Homer Defeated`
  - Description: `Defeat Homer.`

- [ ] `ACH_BEAT_MAGGIE`
  - Display: `Maggie Outplayed`
  - Description: `Defeat Maggie.`

- [ ] `ACH_BEAT_LISA`
  - Display: `Lisa Outmaneuvered`
  - Description: `Defeat Lisa.`

- [ ] `ACH_PLAY_LOCAL`
  - Display: `Couch Commander`
  - Description: `Play a local multiplayer match.`

- [ ] `ACH_PLAY_ONLINE`
  - Display: `Connected Forces`
  - Description: `Play an online match.`

- [ ] `ACH_WIN_ONLINE`
  - Display: `Network Victory`
  - Description: `Win an online match.`

- [ ] `ACH_WIN_BY_COMMANDANT`
  - Display: `Decapitation Strike`
  - Description: `Win by destroying the enemy Commandant.`

- [ ] `ACH_WIN_BY_ELIMINATION`
  - Display: `Total Annihilation`
  - Description: `Win by destroying all enemy units.`

- [ ] `ACH_RATING_1600`
  - Display: `Field Marshal`
  - Description: `Reach a rating of 1600.`

### Publish step

- [ ] Save achievements
- [ ] Publish achievements

## 3. Leaderboard

Create the public rating leaderboard in `Steamworks > Stats & Achievements > Leaderboards`.

Use these exact values:

- [ ] Name = `global_glicko2_v1`
- [ ] Community Name = `Global Rating`
- [ ] Sort order = `Descending`
- [ ] Display type = `Numeric`
- [ ] Writes = client writes allowed / not trusted
- [ ] Reads = public
- [ ] Lobby = empty / none
- [ ] Save
- [ ] Publish

## 4. Steam Cloud

Configure in `Steamworks > Steam Cloud`.

Recommended file sync decisions:

- [ ] Sync `OnlineRatingProfile.dat`
- [ ] Decide whether to sync `LastIncompleteMatch.dat`

Recommended:

- [ ] Yes for `OnlineRatingProfile.dat`
- [ ] Optional for `LastIncompleteMatch.dat`

Cloud setup:

- [ ] Enable Steam Cloud
- [ ] Add the file patterns / roots
- [ ] Save
- [ ] Publish

## 5. Optional Stats

Not strictly required for the current achievements, but recommended for future proofing.

- [ ] `STAT_ONLINE_MATCHES_PLAYED`
- [ ] `STAT_ONLINE_MATCHES_WON`
- [ ] `STAT_LOCAL_MATCHES_PLAYED`
- [ ] `STAT_AI_MATCHES_WON`
- [ ] `STAT_CURRENT_RATING`
- [ ] `STAT_HIGHEST_RATING`

Then:

- [ ] Save
- [ ] Publish

## 6. Cards

Do later, not now.

- [ ] Defer trading cards
- [ ] Revisit only when the app is eligible
- [ ] Remember the trading card count must stay between 5 and 15

## 7. Real Build Validation

When the backend is ready:

- [ ] Confirm the game is packaged and launched with AppID `1573941` in the test packaging flow
- [ ] Test with Steam Overlay active
- [ ] Test achievement unlocks
- [ ] Test leaderboard upload
- [ ] Test Cloud sync between PC and Steam Deck if enabled

## 8. Final Backend Test Pass

- [ ] Start first gameplay -> `ACH_FIRST_ORDERS`
- [ ] Beat Burt -> `ACH_BEAT_BURT`
- [ ] Beat Burns -> `ACH_BEAT_BURNS`
- [ ] Beat Marge -> `ACH_BEAT_MARGE`
- [ ] Beat Homer -> `ACH_BEAT_HOMER`
- [ ] Beat Maggie -> `ACH_BEAT_MAGGIE`
- [ ] Beat Lisa -> `ACH_BEAT_LISA`
- [ ] Play a local multiplayer match -> `ACH_PLAY_LOCAL`
- [ ] Play an online match -> `ACH_PLAY_ONLINE`
- [ ] Win an online match -> `ACH_WIN_ONLINE`
- [ ] Win by destroying the enemy Commandant -> `ACH_WIN_BY_COMMANDANT`
- [ ] Win by destroying all enemy units -> `ACH_WIN_BY_ELIMINATION`
- [ ] Reach 1600 rating -> `ACH_RATING_1600`
- [ ] Confirm leaderboard score updates correctly
- [ ] Confirm Cloud sync preserves rating profile if enabled

## Recommended Order

1. Achievements
2. Leaderboard
3. Steam Cloud
4. Real-app test build
5. Full unlock test pass
6. Cards later
