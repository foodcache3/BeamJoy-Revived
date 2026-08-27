angular.module("beamjoy").component("bjSlider", {
    bindings: {
        ngModel: "=",
        min: "<?",
        max: "<?",
        // optional absolute ceiling/floor beyond `min`/`max`, used only while typing a value in
        // number mode (dragging can never exceed min/max: the range input's own attributes
        // physically cap that), but a typed value between max and hardMax is accepted rather than
        // clamped back down. Per direct request for gate width/height specifically, but built as
        // a generic bj-slider capability.
        hardMin: "<?",
        hardMax: "<?",
        step: "<?",
        disabled: "<?",
    },
    templateUrl: "/ui/modModules/beamjoy/cmps/slider/app.html",
    controller: function ($timeout, $scope, $element) {
        // Redesigned after every attempt at keeping a range input and a number input BOTH live
        // and bound to the same model at once kept breaking in a new way each round (the two
        // inputs, and the browser's/AngularJS's own native input[range] handling, fighting each
        // other). Now there is only ever ONE actual <input> in the DOM at a time : "slider" mode
        // (default) shows the plain native range input plus a read-only text label mirroring its
        // value ; "number" mode swaps to a single plain number input for precise typed entry. A
        // toggle button switches between them. Neither input ever has to coexist/sync with the
        // other, so there's nothing left for them to fight over.
        this.mode = "slider";
        this.toggleMode = () => {
            if (this.disabled) return;
            this.mode = this.mode === "slider" ? "number" : "slider";
            if (this.mode === "number") {
                $timeout(() => {
                    const input = $element[0].querySelector("input[type=number]");
                    if (input) {
                        input.focus();
                        input.select();
                    }
                });
            }
        };

        const updatePercent = () => {
            const min = this.min ?? 0;
            const max = this.max ?? 100;
            this.percent = Math.round(((this.ngModel - min) / (max - min)) * 100);
        };
        // plain properties, computed here rather than inlined as `??` in the template: AngularJS's
        // own expression parser (not real JS) doesn't reliably support the nullish-coalescing
        // operator, so this lives in real JS instead of risking a silent template parse failure.
        const updateNumberRange = () => {
            this.numberMin = this.hardMin ?? this.min ?? -Infinity;
            this.numberMax = this.hardMax ?? this.max ?? Infinity;
        };
        const roundModel = () => {
            const raw = this.ngModel;
            // number mode's input sets the model to `undefined` (AngularJS's own number-input
            // behavior) whenever its raw text is momentarily incomplete (e.g. mid-retype of a
            // digit), so bail out rather than round/clamp/write-back a bogus value over the field
            // the user is still editing.
            if (typeof raw !== "number" || Number.isNaN(raw)) return;
            // real, confirmed bug fixed here ("the reset lock distance slider is set to increments
            // of 1m instead of 10") : this used to hardcode a fixed 0.1 rounding granularity
            // regardless of whatever `step` a given slider was actually configured with. Correct
            // by coincidence for the handful of sliders that happen to want 0.1 precision
            // (huntedStuckDistance, etc.), but silently ignored every slider configured with a
            // coarser step (10m, for example), letting it settle on any value the underlying
            // native range input's own drag/CEF quirks happened to produce instead of snapping to
            // the intended increment. Now snaps to the actual configured `step` (falling back to
            // the old 0.1 only when no step was given at all, matching prior behavior for those).
            const step = this.step > 0 ? this.step : 0.1;
            let value = Math.round(raw / step) * step;
            // guard against floating-point residue (e.g. 0.1 + 0.2-style drift) from the division
            // above before comparing/writing back
            value = Math.round(value * 1e6) / 1e6;
            const min = this.hardMin ?? this.min ?? -Infinity;
            const max = this.hardMax ?? this.max ?? Infinity;
            if (value < min) value = min;
            if (value > max) value = max;
            if (value !== raw) this.ngModel = value;
        };
        $scope.$watch(
            () => this.ngModel,
            () => {
                roundModel();
                updatePercent();
            }
        );
        $scope.$watch(
            () => ({ min: this.min, max: this.max, hardMin: this.hardMin, hardMax: this.hardMax }),
            updateNumberRange,
            true
        );
        roundModel();
        updateNumberRange();
        updatePercent();

        // wheel-to-adjust used to live here (scrolling over the slider nudged its value up/down).
        // Removed per direct request: scrolling a settings page whose cursor happened to pass over
        // a slider silently changed its value along the way, a real, confusing footgun with no
        // opt-out. Sliders are now purely drag/click/type, same as every other input in this
        // codebase, no special-cased wheel behavior.
    },
});
