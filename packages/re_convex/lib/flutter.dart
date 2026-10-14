/// Convex for Flutter (`convex/react`): [ConvexReactClient], its provider and
/// hooks, and the auth helpers.
library;

import 'package:re_convex/src/flutter/client.dart';

export 'package:re_convex/src/browser/query_options.dart'
    show QueryOptions, convexQueryOptions;
export 'package:re_convex/src/browser/sync/client.dart' show AuthTokenFetcher;
export 'package:re_convex/src/browser/sync/pagination.dart'
    show PaginationStatus;
export 'package:re_convex/src/flutter/auth_helpers.dart';
export 'package:re_convex/src/flutter/client.dart'
    show
        ConvexProvider,
        ConvexReactClient,
        ConvexReactClientOptions,
        PaginatedWatch,
        ReactAction,
        ReactMutation,
        UseQueryError,
        UseQueryPending,
        UseQueryResult,
        UseQuerySuccess,
        Watch,
        useAction,
        useConvex,
        useConvexConnectionState,
        useMutation,
        useQuery,
        useQuery_experimental;
export 'package:re_convex/src/flutter/connectivity.dart';
export 'package:re_convex/src/flutter/convex_auth_state.dart'
    show
        ConvexAuthController,
        ConvexAuthProviderState,
        ConvexAuthState,
        ConvexProviderWithAuth,
        IConvexReactClient,
        useConvexAuth;
export 'package:re_convex/src/flutter/use_paginated_query.dart'
    show
        PaginatedQueryReference,
        SortOrder,
        UsePaginatedQueryResult,
        insertAtBottomIfLoaded,
        insertAtPosition,
        insertAtTop,
        optimisticallyUpdateValueInPaginatedQuery,
        usePaginatedQuery;
export 'package:re_convex/src/flutter/use_paginated_query2.dart'
    show usePaginatedQuery_experimental;
export 'package:re_convex/src/flutter/use_queries.dart'
    show QueryRequest, RequestForQueries, useQueries;
