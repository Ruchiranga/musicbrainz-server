// This file is part of MusicBrainz, the open internet music database.
// Copyright (C) 2014 MetaBrainz Foundation
// Licensed under the GPL version 2, or (at your option) any later version:
// http://www.gnu.org/licenses/gpl-2.0.txt

var mergeDates = require('./mergeDates.js');
var deferFocus = require('../../edit/utility/deferFocus.js');

(function (RE) {

    MB.entity.CoreEntity.extend({

        after$init: function () {
            this.uniqueID = _.uniqueId("entity-");
            this.relationshipElements = {};
        },

        parseRelationships: function (relationships) {
            var self = this;

            if (!relationships || !relationships.length) {
                return;
            }

            var newRelationships = _(relationships)
                .map(function (data) { return MB.getRelationship(data, self) })
                .compact()
                .value();

            var allRelationships = _(this.relationships.peek())
                .union(newRelationships)
                .sortBy(function (r) { return r.lowerCasePhrase(self) })
                .value();

            this.relationships(allRelationships);

            _.each(relationships, function (data) {
                MB.entity(data.target).parseRelationships(data.target.relationships);
            });
        },

        displayableRelationships: cacheByID(function (vm) {
            return vm._sortedRelationships(this.relationshipsInViewModel(vm), this);
        }),

        relationshipsInViewModel: cacheByID(function (vm) {
            var self = this;
            return this.relationships.filter(function (relationship) {
                return vm === relationship.parent;
            });
        }),

        groupedRelationships: cacheByID(function (vm) {
            var self = this;

            function linkPhrase(relationship) {
                return relationship.linkPhrase(self);
            }

            function openAddDialog(source, event) {
                var relationships = this.values(),
                    firstRelationship = relationships[0];

                var dialog = RE.UI.AddDialog({
                    source: self,
                    target: MB.entity({}, firstRelationship.target(self).entityType),
                    direction: self === firstRelationship.entities()[1] ? "backward" : "forward",
                    viewModel: vm
                });

                var relationship = dialog.relationship();
                relationship.linkTypeID(firstRelationship.linkTypeID());

                var attributeLists = _.invoke(relationships, "attributes");

                var commonAttributes = _.map(
                    _.reject(_.intersection.apply(_, attributeLists), isFreeText),
                    function (attr) {
                        return { type: { gid: attr.type.gid } };
                    }
                );

                relationship.setAttributes(commonAttributes);
                deferFocus("input.name", "#dialog");
                dialog.open(event.target);
                return dialog;
            }

            return this.displayableRelationships(vm)
                .groupBy(linkPhrase).sortBy("key").map(function (group) {
                    group.openAddDialog = openAddDialog;
                    return group;
                });
        }),

        // searches this entity's relationships for potential duplicate "rel"
        // if it is a duplicate, remove and merge it

        mergeRelationship: function (rel) {
            var relationships = this.relationships();

            for (var i = 0; i < relationships.length; i++) {
                var other = relationships[i];

                if (rel !== other && rel.isDuplicate(other)) {
                    var obj = _.omit(rel.editData(), "id");

                    obj.beginDate = mergeDates(rel.period.beginDate, other.period.beginDate);
                    obj.endDate = mergeDates(rel.period.endDate, other.period.endDate);

                    other.fromJS(obj);
                    rel.remove();

                    return true;
                }
            }
            return false;
        }
    });


    MB.entity.Recording.extend({

        after$init: function () {
            this.performances = this.relationships.filter(isPerformance);
        }
    });


    function isPerformance(relationship) {
        return relationship.entityTypes === "recording-work";
    }

    function isFreeText(linkAttribute) {
        return MB.attrInfoByID[linkAttribute.type.id].freeText;
    }

    function cacheByID(func) {
        var cacheID = _.uniqueId("cache-");

        return function (vm) {
            var cache = this[cacheID] = this[cacheID] || {};
            return cache[vm.uniqueID] || (cache[vm.uniqueID] = func.call(this, vm));
        };
    }

}(MB.relationshipEditor = MB.relationshipEditor || {}));
