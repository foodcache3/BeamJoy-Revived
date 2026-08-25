// shared by both the `tooltip` directive below and the automatic title->tooltip conversion in the
// .run() block. Plain DOM event wiring, no Angular compilation involved, so it can be safely
// re-applied to an element that's already been compiled by Angular elsewhere (see why that matters
// below) without touching any of that element's own directives.
//
// getText is a function (not a plain string) so the directive's own usage can keep reading a live,
// possibly-changing `attrs.tooltip` value, while the auto-conversion below can just close over its
// fixed captured title string.
function bindTooltip(domEl, getText) {
    let tooltipEl;

    function showTooltip() {
        const text = getText();
        if (!text) return;
        const parent = domEl.getBoundingClientRect();
        if (!tooltipEl) {
            tooltipEl = document.querySelector("beamjoy-tooltip");
        }
        tooltipEl.querySelector("tooltip-content").innerText = text;
        const viewport = {
            x: window.innerWidth,
            y: window.innerHeight,
        };
        const parentCenter = {
            x: parent.left + parent.width / 2,
            y: parent.top + parent.height / 2,
        };
        tooltipEl.style.inset = "unset";
        tooltipEl.style.top = `${parentCenter.y}px`;
        if (parentCenter.x < viewport.x / 2) {
            tooltipEl.style.left = `${parent.right}px`;
        } else {
            tooltipEl.style.right = `${viewport.x - parent.left}px`;
        }
        tooltipEl.classList.add("show");
    }

    function hideTooltip() {
        if (tooltipEl) {
            tooltipEl.classList.remove("show");
            setTimeout(() => {
                if (tooltipEl.classList.contains("show")) return;
                tooltipEl.querySelector("tooltip-content").innerText = "";
            }, 200);
        }
    }

    domEl.addEventListener("mouseenter", showTooltip);
    domEl.addEventListener("mouseleave", hideTooltip);
    domEl.addEventListener("click", hideTooltip);
    return hideTooltip;
}

angular
    .module("beamjoy")
    .directive("tooltip", function () {
        return {
            restrict: "A",
            link: function (scope, element, attrs) {
                const hideTooltip = bindTooltip(element[0], () => attrs.tooltip);
                scope.$on("$destroy", hideTooltip);
            },
        };
    })
    .run(function ($rootScope, $timeout) {
        if (document.querySelector("beamjoy-tooltip")) return;

        const tooltip = document.createElement("beamjoy-tooltip");
        tooltip.appendChild(document.createElement("tooltip-content"));
        document.body.prepend(tooltip);

        // elements not yet retrofitted, so a repeat MutationObserver pass doesn't rebind the same
        // element's tooltip listeners over and over
        const processed = new WeakSet();

        function processTitles() {
            document.querySelectorAll("[title]").forEach((el) => {
                if (processed.has(el)) return;
                const title = el.getAttribute("title");
                if (!title) return;
                // this MutationObserver fires, and re-scans the ENTIRE document (not just the
                // mutated subtree), on literally any DOM change anywhere in the whole UI, which
                // can easily land inside the same tick a freshly-inserted element's own
                // title="{{...}}" attribute interpolation hasn't resolved yet (a component whose
                // own template is fetched async, like bj-slider or icon, is especially prone to
                // this: its template's DOM lands in one mutation, but Angular's own interpolation
                // watcher for it can settle a tick later). Grabbing and permanently capturing a
                // still-raw "{{...}}" string here, then stripping the attribute so Angular's own
                // interpolation directive never gets a chance to finish resolving it, was a real,
                // confirmed-reproducing bug (the Freeroam ghost-timeout slider's own mode-toggle
                // button, which carries a title of its own, sometimes rendering literally as
                // "{{$ctrl.mode === 'slider' ? '#' : '≡'}}" instead of resolving). Skip it this
                // pass and leave the attribute untouched: Angular's native title interpolation is
                // completely independent of this retrofit and will resolve it on its own regardless ;
                // the very next mutation anywhere (which in an active UI is never far away) re-
                // triggers this scan and picks it up correctly once it has settled.
                if (title.includes("{{")) return;
                el.removeAttribute("title");
                processed.add(el);
                // plain DOM listener wiring (bindTooltip above), NOT $compile(el)($rootScope):
                // this element is almost always already Angular-compiled with its own scope-bound
                // directives (ng-show, ng-click, ng-repeat's own child scope, etc.) from wherever
                // it actually lives in the app ; re-$compile'ing the WHOLE element against
                // $rootScope silently broke every one of those. Confirmed root cause of a real,
                // very confusing bug report : the Config > Races Delete button's own
                // ng-show="$ctrl.canManage(race)" got re-linked against $rootScope (where $ctrl
                // doesn't exist), permanently hiding it. And since this MutationObserver reprocesses
                // on literally every DOM mutation ANYWHERE in the whole UI (any tab switching, any
                // toast, any other row rendering), it kept re-breaking it moments after every
                // Angular-driven re-render happened to briefly get it right. Wiring the tooltip's
                // hover/click listeners directly can't touch anything else on the element at all.
                bindTooltip(el, () => title);
            });
        }

        // init
        processTitles();

        const observer = new MutationObserver(() => {
            $timeout(processTitles, 0);
        });
        observer.observe(document.body, { childList: true, subtree: true });

        $rootScope.$on("BJUnload", () => {
            document.querySelector("beamjoy-tooltip").remove();
        });
    });
