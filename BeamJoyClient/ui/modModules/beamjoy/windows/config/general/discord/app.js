// Config > General > Discord : a list of webhooks, each with its own name, URL and choice of posts.
// Edits stay local until Save (like the Broadcasts panel), so a half-typed URL never reaches the
// server, which rejects anything that isn't a Discord webhook anyway. Test posts go to the SAVED
// webhook, so they're only offered while nothing is unsaved.
const WEBHOOK_RE =
    /^https:\/\/(discord\.com|ptb\.discord\.com|canary\.discord\.com|discordapp\.com)\/api\/webhooks\/\d+\/[\w-]+$/;
const WEBHOOKS_MAX = 10;
const TOGGLES = {
    RaceFinishes: true,
    RacePBsOnly: false,
    Votes: true,
    JoinLeave: false,
    Chat: false,
    Deliveries: false,
    Hunter: false,
    Infected: false,
    Derby: false,
    BusLines: false,
};

const normalize = (hook, i) => {
    const out = { Name: hook.Name || `Webhook ${i + 1}`, Url: hook.Url || "" };
    Object.keys(TOGGLES).forEach((key) => {
        out[key] = typeof hook[key] === "boolean" ? hook[key] : TOGGLES[key];
    });
    return out;
};

angular.module("beamjoy").component("bjConfigGeneralDiscord", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/general/discord/app.html",
    controller: function ($scope, beamjoyStore) {
        this.init = false;
        this.saved = [];
        this.hooks = [];
        this.shown = {};
        this.max = WEBHOOKS_MAX;

        this.urlValid = (hook) => hook.Url.trim() === "" || WEBHOOK_RE.test(hook.Url.trim());
        this.valid = () => this.hooks.every(this.urlValid);
        this.dirty = () => !angular.equals(this.hooks, this.saved);

        this.add = () => {
            if (this.hooks.length >= WEBHOOKS_MAX) return;
            this.hooks.push(normalize({}, this.hooks.length));
        };
        this.remove = (i) => this.hooks.splice(i, 1);
        this.save = () => {
            if (!this.dirty() || !this.valid()) return;
            const list = this.hooks.map((h) => angular.extend({}, h, { Url: h.Url.trim() }));
            beamjoyStore.send("BJDirectSend", ["setConfig", "Discord", { Webhooks: list }]);
        };
        this.discard = () => {
            this.hooks = angular.copy(this.saved);
        };
        this.canTest = (i) => !this.dirty() && !!this.saved[i] && !!this.saved[i].Url;
        this.test = (i) => {
            if (this.canTest(i)) beamjoyStore.send("BJDirectSend", ["discordTest", i + 1]);
        };

        $scope.$on("BJSendConfigData", (_, data) => {
            const d = data.Discord || {};
            // a config saved before several webhooks existed: one URL, its toggles alongside
            const list = Array.isArray(d.Webhooks)
                ? d.Webhooks
                : d.WebhookUrl
                ? [angular.extend({ Name: "Discord", Url: d.WebhookUrl }, d)]
                : [];
            const hadEdits = this.init && this.dirty();
            this.saved = list.map(normalize);
            // a save elsewhere re-sends the config : keep edits in progress here
            if (!hadEdits) this.hooks = angular.copy(this.saved);
            this.init = true;
        });
    },
});
