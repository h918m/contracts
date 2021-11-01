// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;


// TODO route ysOHM for different recipients
contract Router {

	struct Route {
		address destination;
		uint256 weight;
	}

	struct RoutingTable {
		uint256 totalAmount;
		uint256 totalWeight;
		Route[] routes;
	}
	
	mapping(address => RoutingTable) public userRoutes;

	constructor() {}

	/**
		@notice Creates RoutingTable for a given address origin
	 */
	function createRoutingTable(address origin_, address destination_, uint256 weight) public {
		require(weight > 0);
		require(destination_ != address(0));

		// TODO Find or create RouteInfo for origin

		// TODO Add route to RouteInfo
	}

	function updateRoute(address origin_, address destination_, uint256 weight) public {
		require(weight > 0);
		require(destination_ != address(0));

		// TODO Find or create RouteInfo for origin
		// TODO Change route weight
	}

	function removeRoute(address origin_, address destination_) public {
		require(destination_ != address(0));

		// TODO Find RouteInfo for origin
		// TODO Delete route from RouteInfo
	}

	function deleteRoutingTable(address origin_) public {
		// TODO Find RouteInfo for origin
	}

	function getRouteWeight(address origin_, address destination_) public view returns (uint256) {
		// TODO Call _getRoute
		// TODO return route weight if exists, else return 0
	}

	function _getRouteIndex(address origin_, address destination_) internal view returns (int256) {
		// TODO Find RouteInfo for origin
		// TODO return index if exists, else return -1
	}
}