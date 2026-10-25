/// Route paths, in one place so screens don't hard-code strings.
abstract final class Routes {
  static const splash = '/splash';
  static const signIn = '/sign-in';
  static const home = '/';
  static const manageUsers = '/admin/users';
  static const manageSites = '/admin/sites';
  static const activity = '/activity';
  static const export = '/admin/export';
  static const settings = '/settings';
  static const site = '/sites/:siteId';
  static const addEntry = '/entries/add';
  static const entry = '/entries/:entryId';
  static const editEntry = '/entries/:entryId/edit';
  static const join = '/join/:token';

  static String sitePath(String siteId) => '/sites/$siteId';
  static String addEntryPath(String siteId) => '$addEntry?siteId=$siteId';
  static String entryPath(String entryId) => '/entries/$entryId';
  static String editEntryPath(String entryId) => '/entries/$entryId/edit';
}
