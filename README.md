# Animal Redux (FS25)

An extension to [Distribution Redux](https://github.com/Bones50/FS25-Distribution-Redux)
that deepens Farming Simulator 25's animal husbandry.

**Animal Redux requires Distribution Redux.** It declares a hard dependency and
disables itself with a log message if Distribution Redux is not installed.

## WARNING
This is a pre-release version and will have bugs that may impact you savegame in unintended ways. I highly reccomend you create a savegame copy and test the mod there first.

## Status

V0.0.0.1 - Pre-Release Test Version
FEATURES
1) Advanced animal feeder - Takes into account animals that require ratio's of food and supplies that to the distribution redux mod as demand rather than the default demand. Where possible DR will supply all relevant foods at the require proportions to ensure 100% health. NOTE: Requires Distribution Redux to be installed for this to work.
2) Barn/Herd Inspector - Allows you to view the status of all animals in one view, as well as the status of each barn in detail. 
3) Herd Adviser - montior animals/barns, provides advice and embeds it in the Barn/Herd Inspector. Examples would be No room for new births, sell animals to make space, or add root crops to the horse barn to maximise health/value, or animals have passed their prime and are losing value so sell them. 
4) Animal Buy/Sell - replaces the default game buy/sell screens so you can do it all from directly within the mod.
5) Animal AutoTrader - Allows a user to place buy orders and sell orders for animals over time (e.g. buy/Sell X Cows, every Y Months for Z Months) per barn.
6) UI - Added a new tab for animal redux to the Distribution Redux page and embedded additional details in the DR Animal Husbandry UI.
7) Multilingual Support - Pre built with l10n support.

## Known Issues
1) Advanced Animal feeding is not working with Barns with an autofeeder - currently being worked on
2) Herd Adviser - Some issues with the advice given due to not enough granularity in the animal data - currently being worked on
3) Animal Auto-Trader - Same granularity issue above applies to the autotrader, have turned it off in the settings for now while i rebuild. You can reactivate but at best it will not work as intended, and at worst it may mess with your animals in unintended ways.

## WIP Features
1) Manure for all Barns
2) Remove dependency on Distribution Redux


## Contributing translations

Copy `translations/translation_en.xml` to `translation_<code>.xml` and translate
the `text` attributes. Any key you leave out falls back to English, so partial
translations are welcome.

An XML comment must not contain a double hyphen — it is a parse error and the
file will not load.

NOTE: The mod is constantly changing so might be worth waiting a while until things settle down before creating translations.
