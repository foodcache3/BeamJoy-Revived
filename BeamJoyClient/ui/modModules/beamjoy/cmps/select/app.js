angular.module("beamjoy").component("bjSelect", {
    bindings: {
        ngModel: "=",
        options: "<",
        ngChange: "&?",
    },
    templateUrl: "/ui/modModules/beamjoy/cmps/select/app.html",
    controller: function ($scope, $timeout) {
        this.renderKey = 1;
        $scope.$watch(
            () => this.options,
            () => {
                const next = this.renderKey + 1;
                this.renderKey = undefined;
                $timeout(() => (this.renderKey = next), 0);
            },
            true
        );
        this.handleChange = () => {
            // "&" bindings ignore positional arguments; they take a named-locals object, exposed
            // to the caller's expression as `value` (e.g. ng-change="$ctrl.onPick(item, value)").
            // Passing the value explicitly matters: at the moment ng-change fires, the two-way
            // ngModel copy back to the PARENT scope's property has not run yet (that happens
            // later in the digest), so a caller reading its own bound property from inside
            // ng-change gets the stale pre-change value. Confirmed real bug: the race lobby's
            // manual grid-slot dropdown sent the OLD slot to the server, which no-op'd it.
            if (this.ngChange) this.ngChange({ value: this.ngModel });
        };
    },
});
