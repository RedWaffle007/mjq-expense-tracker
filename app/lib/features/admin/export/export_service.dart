import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel_community/excel_community.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../../../data/entries/entry_repository.dart';
import '../../../data/entries/expense_entry.dart';
import '../../../data/photos/photo_repository.dart';
import '../../../data/sites/site.dart';
import '../../../data/sites/site_repository.dart';
import '../../../data/users/user_repository.dart';
import '../../../data/users/app_user.dart';

enum ExportRange { thisMonth, allTime }

List<ExpenseEntry> entriesForExportRange(
  List<ExpenseEntry> entries,
  ExportRange range,
  DateTime now,
) => entries
    .where((entry) => exportIncludesDate(entry.expenseDate, range, now))
    .toList();

bool exportIncludesDate(DateTime date, ExportRange range, DateTime now) {
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  final start = DateTime(now.year, now.month);
  return date.isBefore(tomorrow) &&
      (range == ExportRange.allTime || !date.isBefore(start));
}

class ExportService {
  ExportService(
    this._entries,
    this._sites,
    this._users,
    this._photos,
    this._db,
  );
  final EntryRepository _entries;
  final SiteRepository _sites;
  final UserRepository _users;
  final PhotoRepository _photos;
  final FirebaseFirestore _db;

  Future<File> generate(ExportRange range) async {
    final results = await Future.wait([
      _entries.allForExport(),
      _sites.allForExport(),
      _users.allForExport(),
    ]);
    final entries = entriesForExportRange(
      results[0] as List<ExpenseEntry>,
      range,
      DateTime.now(),
    );
    final sites = results[1] as List<Site>;
    final users = results[2] as List<AppUser>;
    final names = {for (final user in users) user.uid: user.name};
    final ids = entries
        .expand((entry) => entry.photos.map((p) => p.publicId))
        .toList();
    final urls = <String, String>{};
    for (var start = 0; start < ids.length; start += 30) {
      urls.addAll(
        await _photos.viewUrls(
          ids.sublist(start, (start + 30).clamp(0, ids.length)),
        ),
      );
    }

    final excel = Excel.createExcel();
    excel.rename('Sheet1', _uniqueSheetName('All Sites', {}));
    final used = <String>{'All Sites'};
    for (final site in sites) {
      final sheetName = _uniqueSheetName(site.name, used);
      used.add(sheetName);
      _fillSheet(
        excel[sheetName],
        entries.where((e) => e.siteId == site.id).toList(),
        names,
        urls,
      );
    }
    final all = excel['All Sites'];
    _fillSheet(
      all,
      entries,
      names,
      urls,
      includeSite: true,
      siteNames: {for (final site in sites) site.id: site.name},
    );
    var row = all.maxRows + 2;
    all.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value =
        TextCellValue('Site summary');
    row++;
    var grand = 0;
    for (final site in sites) {
      final total = entries
          .where((e) => e.siteId == site.id)
          .fold<int>(0, (total, e) => total + e.amount);
      grand += total;
      all.appendRow([TextCellValue(site.name), DoubleCellValue(total / 100)]);
    }
    all.appendRow([TextCellValue('Grand total'), DoubleCellValue(grand / 100)]);
    final bytes = excel.encode();
    if (bytes == null) throw StateError('Could not create workbook.');
    final directory = await getApplicationDocumentsDirectory();
    final stamp = DateFormat('yyyy-MM-dd_HHmm').format(DateTime.now());
    final rangeName = range == ExportRange.thisMonth
        ? 'This_Month'
        : 'All_Time';
    final file = File('${directory.path}/Expenses_${rangeName}_$stamp.xlsx');
    await file.writeAsBytes(bytes, flush: true);
    await _db.collection('config').doc('app').set({
      'lastExportAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    return file;
  }

  void _fillSheet(
    Sheet sheet,
    List<ExpenseEntry> entries,
    Map<String, String> names,
    Map<String, String> urls, {
    bool includeSite = false,
    Map<String, String> siteNames = const {},
  }) {
    sheet.frozenRows = 1;
    final headers = [
      if (includeSite) 'Site',
      'Date',
      'Item',
      'Category',
      'Quantity',
      'Unit',
      'Rate',
      'Amount (₹)',
      'Vendor',
      'Note',
      'Entered by',
      'Entered at',
      'Last edited by',
      'Last edited at',
      for (var photo = 1; photo <= 10; photo++) 'Bill photo $photo',
      'Entry ID',
    ];
    sheet.appendRow(headers.map(TextCellValue.new).toList());
    final headerStyle = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.blue100,
    );
    for (var col = 0; col < headers.length; col++) {
      sheet
              .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 0))
              .cellStyle =
          headerStyle;
      sheet.setColumnWidth(
        col,
        col == 2 || col == 9
            ? 28
            : col >= 14 && col < 24
            ? 38
            : 16,
      );
    }
    final moneyStyle = CellStyle(
      numberFormat: const CustomNumericNumFormat(formatCode: '₹#,##,##0.00'),
    );
    for (final entry in entries) {
      final links = entry.photos.map((p) => urls[p.publicId]).nonNulls.toList();
      sheet.appendRow([
        if (includeSite) TextCellValue(siteNames[entry.siteId] ?? entry.siteId),
        TextCellValue(DateFormat('dd/MM/yyyy').format(entry.expenseDate)),
        TextCellValue(entry.item),
        TextCellValue(entry.category.label),
        switch (num.tryParse(entry.quantity ?? '')) {
          final number? => DoubleCellValue(number.toDouble()),
          null => TextCellValue(entry.quantity ?? ''),
        },
        TextCellValue(entry.unit ?? ''),
        entry.rate == null
            ? TextCellValue('')
            : DoubleCellValue(entry.rate! / 100),
        DoubleCellValue(entry.amount / 100),
        TextCellValue(entry.vendor ?? ''),
        TextCellValue(entry.note ?? ''),
        TextCellValue(names[entry.createdBy] ?? entry.createdBy),
        TextCellValue(
          entry.createdAt == null
              ? ''
              : DateFormat('dd/MM/yyyy HH:mm').format(entry.createdAt!),
        ),
        TextCellValue(names[entry.updatedBy] ?? entry.updatedBy),
        TextCellValue(
          entry.updatedAt == null
              ? ''
              : DateFormat('dd/MM/yyyy HH:mm').format(entry.updatedAt!),
        ),
        for (var photo = 0; photo < 10; photo++)
          photo < links.length
              ? FormulaCellValue(
                  'HYPERLINK("${links[photo].replaceAll('"', '""')}","Open photo ${photo + 1}")',
                )
              : TextCellValue(''),
        TextCellValue(entry.id),
      ]);
      final offset = includeSite ? 1 : 0;
      sheet
              .cell(
                CellIndex.indexByColumnRow(
                  columnIndex: 6 + offset,
                  rowIndex: sheet.maxRows - 1,
                ),
              )
              .cellStyle =
          moneyStyle;
      sheet
              .cell(
                CellIndex.indexByColumnRow(
                  columnIndex: 7 + offset,
                  rowIndex: sheet.maxRows - 1,
                ),
              )
              .cellStyle =
          moneyStyle;
    }
    final total = entries.fold<int>(0, (value, entry) => value + entry.amount);
    sheet.appendRow([TextCellValue('Total'), DoubleCellValue(total / 100)]);
    final subtotals = <ExpenseCategory, int>{};
    for (final entry in entries) {
      subtotals[entry.category] =
          (subtotals[entry.category] ?? 0) + entry.amount;
    }
    sheet.appendRow([TextCellValue('Category subtotals')]);
    for (final category in ExpenseCategory.values) {
      sheet.appendRow([
        TextCellValue(category.label),
        DoubleCellValue((subtotals[category] ?? 0) / 100),
      ]);
    }
  }

  String _uniqueSheetName(String input, Set<String> used) {
    var base = input.replaceAll(RegExp(r'[\\/*?:\[\]]'), ' ').trim();
    if (base.isEmpty) base = 'Site';
    if (base.length > 31) base = base.substring(0, 31);
    var result = base;
    var suffix = 2;
    while (used.contains(result)) {
      final tail = ' ($suffix)';
      result =
          '${base.substring(0, (31 - tail.length).clamp(0, base.length))}$tail';
      suffix++;
    }
    return result;
  }
}
