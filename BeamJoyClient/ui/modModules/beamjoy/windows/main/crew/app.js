// Crew : your crew (services/crews.lua through beamjoy/crews.lua). A crew rides together : when
// its leader opens a race, hunt, infected game or convoy, every crewmate who's free joins it.
// Not in a crew : create one, or join / ask to join one from the list. In one : the formation
// (one slanted seat per member, its signal bars saying who's free, busy or offline), the
// leader's requests and invites, Leave.
//
// beamjoyCrew keeps the state for the whole session : the rail's badge (join requests) and the
// Players tab's "Invite to crew" read it while this tab is closed.
angular.module("beamjoy").service("beamjoyCrew", function ($rootScope, beamjoyStore) {
    this.crew = null;
    this.list = [];
    $rootScope.$on("BJCrew", (_, crew) => (this.crew = crew || null));
    $rootScope.$on("BJCrewList", (_, list) => (this.list = Array.isArray(list) ? list : []));
    this.refresh = () => beamjoyStore.send("BJCrewRequest");

    this.isLeader = () => !!this.crew && this.crew.isLeader;
    this.requestCount = () => (this.isLeader() && Array.isArray(this.crew.requests) ? this.crew.requests.length : 0);
    // someone in no crew at all : the leader can invite them
    this.inAnyCrew = (playerName) =>
        this.list.some((c) => Array.isArray(c.memberNames) && c.memberNames.includes(playerName));
    this.canInvite = (playerName) =>
        this.isLeader() && this.crew.members.length < this.crew.max && !this.inAnyCrew(playerName);
    this.invite = (playerID) => beamjoyStore.send("BJCrewInvite", [playerID]);
});

angular.module("beamjoy").component("bjMainCrew", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/crew/app.html",
    bindings: {
        full: "<",
    },
    controller: function ($rootScope, $scope, $element, $filter, $interval, beamjoyStore, beamjoyCrew) {
        const translate = $filter("translate");
        this.c = beamjoyCrew;
        this.$onInit = () => beamjoyCrew.refresh();
        // four seats across in the full window, two by two in the side panel
        this.$onChanges = () => $element.toggleClass("is-full", !!this.full);

        // CREATE
        this.newName = "";
        this.create = () => {
            beamjoyStore.send("BJCrewCreate", [this.newName.trim()]);
            this.newName = "";
        };

        // THE LIST : join an open crew, ask a closed one
        this.otherCrews = () => beamjoyCrew.list;
        this.seats = (crew) => {
            const out = [];
            for (let i = 0; i < (crew.max || 8); i++) out.push(i < crew.count);
            return out;
        };
        this.joinLabel = (crew) => {
            if (crew.count >= crew.max) return "beamjoy.crew.full";
            return crew.open ? "beamjoy.crew.join" : "beamjoy.crew.ask";
        };
        this.join = (crew) => {
            if (crew.count < crew.max) beamjoyStore.send("BJCrewJoin", [crew.id]);
        };

        // THE FORMATION : one seat per member, then the open seats. Built once per push (a fresh
        // array per digest never settles)
        this.seatsOf = [];
        $scope.$watch(
            () => beamjoyCrew.crew,
            (crew) => {
                if (!crew) {
                    this.seatsOf = [];
                    this.selected = null;
                    this.inviting = false;
                    return;
                }
                this.openModel = !!crew.open;
                const seats = crew.members.map((m) => ({ key: m.playerName, member: m }));
                for (let i = seats.length; i < crew.max; i++) seats.push({ key: `open${i}`, open: true });
                this.seatsOf = seats;
                if (this.selected && !crew.members.some((m) => m.playerName === this.selected)) this.selected = null;
            }
        );
        // how many signal bars light up : free 3, busy 2, offline none
        this.bars = (status) => ({ free: 3, withYou: 3, busy: 2 })[status] || 0;
        // "joins your activities" is only true from the leader's side
        this.statusLine = (m) =>
            translate(m.status === "free" && !beamjoyCrew.isLeader() ? "beamjoy.crew.status.freePlain" : `beamjoy.crew.status.${m.status}`);

        // the leader picks a seat for its actions (make leader, remove)
        this.selected = null;
        this.pick = (seat) => {
            if (seat.open) {
                if (beamjoyCrew.isLeader()) this.setInviting(true);
                return;
            }
            if (!beamjoyCrew.isLeader() || seat.member.you) return;
            this.selected = this.selected === seat.member.playerName ? null : seat.member.playerName;
        };
        this.selectedMember = () =>
            beamjoyCrew.crew && beamjoyCrew.crew.members.find((m) => m.playerName === this.selected);
        this.promoteLabel = () =>
            translate("beamjoy.crew.promoteNamed").replace("{name}", (this.selectedMember() || {}).displayName || "");
        this.promote = () => {
            beamjoyStore.send("BJCrewPromote", [this.selected]);
            this.selected = null;
        };
        this.kick = () => {
            beamjoyStore.send("BJCrewKick", [this.selected]);
            this.selected = null;
        };

        // what joining means right now, in one line
        this.pullLine = () => {
            const crew = beamjoyCrew.crew;
            if (!crew) return "";
            const free = crew.members.filter((m) => !m.leader && m.status === "free").length;
            if (crew.isLeader) {
                if (crew.members.length === 1) return translate("beamjoy.crew.pull.alone");
                return translate(free === 1 ? "beamjoy.crew.pull.leaderOne" : "beamjoy.crew.pull.leader").replace("{count}", free);
            }
            const leader = crew.members.find((m) => m.leader);
            return translate("beamjoy.crew.pull.member").replace("{name}", leader ? leader.displayName : "?");
        };

        // the leader's "Open to anyone" toggle (bj-toggle has no ng-change : watch its own model)
        this.openModel = false;
        $scope.$watch(
            () => this.openModel,
            (open, old) => {
                const crew = beamjoyCrew.crew;
                if (open !== old && crew && crew.isLeader && open !== !!crew.open) beamjoyStore.send("BJCrewSetOpen", [open]);
            }
        );
        this.reply = (req, accept) => beamjoyStore.send("BJCrewRequestReply", [req.playerName, accept]);
        this.leave = () => beamjoyStore.send("BJCrewLeave");

        // INVITES : everyone online, refreshed while open (an invite lapses after 30 s)
        this.inviting = false;
        this.invitePlayers = null;
        const offList = $rootScope.$on("BJCrewInviteList", (_, data) => {
            this.invitePlayers = data && Array.isArray(data.players) ? data.players : [];
        });
        let refresh = null;
        this.setInviting = (open) => {
            this.inviting = open;
            this.selected = null;
            $interval.cancel(refresh);
            if (open) {
                this.invitePlayers = null;
                beamjoyStore.send("BJCrewInviteList");
                refresh = $interval(() => beamjoyStore.send("BJCrewInviteList"), 3000);
            }
        };
        this.inviteStatus = (p) => {
            if (p.invited) return translate("beamjoy.delivery.lobby.inviteSent");
            if (p.inCrew) return translate("beamjoy.crew.inACrew");
            return "";
        };
        this.invite = (p) => {
            if (!p.invited && !p.inCrew) beamjoyCrew.invite(p.playerID);
        };
        $scope.$on("$destroy", () => {
            offList();
            $interval.cancel(refresh);
        });
    },
});
