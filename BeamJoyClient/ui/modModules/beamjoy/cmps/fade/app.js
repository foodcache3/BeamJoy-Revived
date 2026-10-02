angular.module("beamjoy").run(function ($rootScope, $timeout) {
    if (!document.querySelector("beamjoy-fade")) {
        const fadeWrapper = document.createElement("beamjoy-fade");
        const fadeTop = document.createElement("fade");
        fadeTop.classList.add("top");
        fadeWrapper.appendChild(fadeTop);
        const fadeBottom = document.createElement("fade");
        fadeBottom.classList.add("bottom");
        fadeWrapper.appendChild(fadeBottom);
        document.body.prepend(fadeWrapper);
    }

    const canInit = () => {
        return (
            document.querySelector("beamjoy-fade > fade.bottom") !== undefined
        );
    };
    const init = () => {
        const top = document.querySelector("beamjoy-fade > fade.top");
        const bottom = document.querySelector("beamjoy-fade > fade.bottom");

        const getTransitionVal = (delay) => {
            return `transform ${delay || 0}ms ease-in-out`;
        };

        let state = false;
        $rootScope.$on("BJFade", (_, payload) => {
            top.style.transition = getTransitionVal(payload.delay);
            bottom.style.transition = getTransitionVal(payload.delay);
            if (payload.state !== state) {
                $timeout(() => {
                    state = payload.state;
                    if (state) {
                        top.classList.add("closed");
                        bottom.classList.add("closed");
                    } else {
                        top.classList.remove("closed");
                        bottom.classList.remove("closed");
                    }
                }, 1);
            }
        });
    };

    const process = () => {
        if (canInit()) {
            clearInterval(interval);
            init();
        }
    };
    const interval = setInterval(process, 100);
    process();

    $rootScope.$on("BJUnload", () => {
        // can arrive twice : remove whatever is still there
        document.querySelectorAll("beamjoy-fade").forEach((el) => el.remove());
    });
});
