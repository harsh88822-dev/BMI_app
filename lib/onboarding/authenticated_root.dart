import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../dashboard/dashboard_screen.dart';
import '../services/session_storage_service.dart';
import '../services/user_api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/bmi_loader.dart';

enum _GateStep { dashboard, uploadId, completeProfile }

class AuthenticatedRoot extends StatefulWidget {
  const AuthenticatedRoot({super.key, required this.onLogout});

  final Future<void> Function() onLogout;

  @override
  State<AuthenticatedRoot> createState() => _AuthenticatedRootState();
}

class _AuthenticatedRootState extends State<AuthenticatedRoot> {
  final UserApiService _userApiService = UserApiService();
  final SessionStorageService _sessionStorageService = SessionStorageService();

  bool _loading = true;
  String? _gateErrorMessage;
  _GateStep _step = _GateStep.dashboard;
  Map<String, dynamic> _profileData = <String, dynamic>{};

  @override
  void initState() {
    super.initState();
    _resolveGate();
  }

  Future<void> _resolveGate() async {
    final profileResult = await _userApiService.getProfile();
    if (!profileResult.ok) {
      if (!mounted) return;
      setState(() {
        _gateErrorMessage =
            profileResult.message ??
            'No internet connection. Please try again.';
        _loading = false;
      });
      return;
    }

    final uploadedFlag = await _sessionStorageService.getGovernmentIdUploaded();
    final profile = profileResult.data is Map<String, dynamic>
        ? profileResult.data as Map<String, dynamic>
        : <String, dynamic>{};

    final complete = _isProfileComplete(profile);
    final hasPhoto = _hasProfilePhoto(profile);
    final hasVerificationRecord = _hasVerificationRecord(profile);
    final hasIdEvidence = uploadedFlag || hasVerificationRecord || hasPhoto;

    _GateStep next;
    if (complete) {
      next = _GateStep.dashboard;
    } else if (!hasIdEvidence) {
      next = _GateStep.uploadId;
    } else {
      next = _GateStep.completeProfile;
    }

    if (hasIdEvidence) {
      await _sessionStorageService.saveGovernmentIdUploaded(true);
    }

    if (!mounted) return;
    setState(() {
      _gateErrorMessage = null;
      _profileData = profile;
      _step = next;
      _loading = false;
    });
  }

  bool _isProfileComplete(Map<String, dynamic> profile) {
    final firstName = (profile['first_name'] ?? '').toString().trim();
    final lastName = (profile['last_name'] ?? '').toString().trim();
    final mobile = (profile['mobile_number'] ?? '').toString().trim();
    final dob = (profile['dob'] ?? '').toString().trim();
    final height = (profile['height_cm'] ?? '').toString().trim();
    final weight = (profile['weight_kg'] ?? '').toString().trim();
    return firstName.isNotEmpty &&
        lastName.isNotEmpty &&
        mobile.isNotEmpty &&
        dob.isNotEmpty &&
        height.isNotEmpty &&
        weight.isNotEmpty;
  }

  bool _hasProfilePhoto(Map<String, dynamic> profile) {
    final photo = (profile['profile_photo'] ?? '').toString().trim();
    return photo.isNotEmpty;
  }

  bool _hasVerificationRecord(Map<String, dynamic> profile) {
    final docStatus = profile['document_id_verified'];
    if (docStatus is String) {
      return docStatus.trim().isNotEmpty;
    }

    final verification = profile['verification'];
    if (verification is Map) return verification.isNotEmpty;
    return false;
  }

  Future<void> _onIdUploaded() async {
    await _sessionStorageService.saveGovernmentIdUploaded(true);
    await _resolveGate();
  }

  Future<void> _onProfileCompleted() async {
    await _resolveGate();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: AppTheme.parchment,
        body: const Center(
          child: BmiLoader(showLabel: true, label: 'Preparing your account…'),
        ),
      );
    }
    if (_gateErrorMessage != null) {
      return Scaffold(
        backgroundColor: AppTheme.parchment,
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.wifi_off_rounded,
                        size: 44,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'We could not reach Clockwork',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _gateErrorMessage!,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 22),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () {
                            setState(() {
                              _loading = true;
                              _gateErrorMessage = null;
                            });
                            _resolveGate();
                          },
                          child: const Text('Try again'),
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextButton(
                        onPressed: widget.onLogout,
                        child: const Text('Sign out'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    switch (_step) {
      case _GateStep.uploadId:
        return _UploadGovernmentIdRequiredScreen(
          userApiService: _userApiService,
          onUploaded: _onIdUploaded,
          onLogout: widget.onLogout,
        );
      case _GateStep.completeProfile:
        return _CompleteProfileRequiredScreen(
          userApiService: _userApiService,
          initialProfileData: _profileData,
          onCompleted: _onProfileCompleted,
          onLogout: widget.onLogout,
        );
      case _GateStep.dashboard:
        return DashboardScreen(onLogout: widget.onLogout);
    }
  }
}

class _UploadGovernmentIdRequiredScreen extends StatefulWidget {
  const _UploadGovernmentIdRequiredScreen({
    required this.userApiService,
    required this.onUploaded,
    required this.onLogout,
  });

  final UserApiService userApiService;
  final Future<void> Function() onUploaded;
  final Future<void> Function() onLogout;

  @override
  State<_UploadGovernmentIdRequiredScreen> createState() =>
      _UploadGovernmentIdRequiredScreenState();
}

class _UploadGovernmentIdRequiredScreenState
    extends State<_UploadGovernmentIdRequiredScreen> {
  final ImagePicker _picker = ImagePicker();
  File? _idFile;
  bool _uploading = false;

  Future<void> _pickId() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    setState(() {
      _idFile = File(picked.path);
    });
  }

  Future<void> _submit() async {
    if (_idFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select government ID image.')),
      );
      return;
    }
    setState(() => _uploading = true);
    final result = await widget.userApiService.uploadGovernmentId(
      idDocumentFile: _idFile!,
    );
    if (!mounted) return;
    setState(() => _uploading = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.ok
              ? (result.message ?? 'ID uploaded successfully.')
              : (result.message ?? 'Unable to upload ID.'),
        ),
      ),
    );

    if (result.ok) {
      await widget.onUploaded();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify your identity'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: _ResponsivePageContainer(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const SizedBox(height: 6),
              Text(
                'Upload a valid government-issued photo ID. Your profile image will appear once our team has verified your document.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: scheme.outline.withValues(alpha: 0.75),
                  ),
                  color: Colors.white,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.badge_outlined),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _idFile == null
                            ? 'No file selected'
                            : _idFile!.path.split('/').last,
                      ),
                    ),
                    TextButton(onPressed: _pickId, child: const Text('Choose')),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _uploading ? null : _submit,
                child: _uploading
                    ? const BmiLoader(size: 20, strokeWidth: 2)
                    : const Text('Upload and Continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompleteProfileRequiredScreen extends StatefulWidget {
  const _CompleteProfileRequiredScreen({
    required this.userApiService,
    required this.initialProfileData,
    required this.onCompleted,
    required this.onLogout,
  });

  final UserApiService userApiService;
  final Map<String, dynamic> initialProfileData;
  final Future<void> Function() onCompleted;
  final Future<void> Function() onLogout;

  @override
  State<_CompleteProfileRequiredScreen> createState() =>
      _CompleteProfileRequiredScreenState();
}

class _CompleteProfileRequiredScreenState
    extends State<_CompleteProfileRequiredScreen> {
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _mobileController = TextEditingController();
  final _dobController = TextEditingController();
  final _heightController = TextEditingController();
  final _weightController = TextEditingController();
  bool _saving = false;

  String? _documentIdVerifiedStatus() {
    final raw = widget.initialProfileData['document_id_verified'];
    final s = raw?.toString().trim().toLowerCase();
    if (s == null || s.isEmpty) return null;
    return s;
  }

  Widget _buildIdentityStatusBanner() {
    final scheme = Theme.of(context).colorScheme;
    final status = _documentIdVerifiedStatus();
    final normalized = status ?? 'pending';

    final isVerified = normalized == 'verified';
    final isRejected = normalized == 'rejected';
    final isPending = !isVerified && !isRejected;

    final Color accent = isVerified
        ? const Color(0xFF2A4A3C)
        : isRejected
        ? scheme.error
        : scheme.primary;
    final Color bg = isVerified
        ? const Color(0xFFF2F7F4)
        : isRejected
        ? const Color(0xFFFBF6F5)
        : scheme.primary.withValues(alpha: 0.07);
    final Color border = isVerified
        ? const Color(0xFFD0E3D8)
        : isRejected
        ? scheme.error.withValues(alpha: 0.22)
        : scheme.primary.withValues(alpha: 0.18);

    final IconData icon = isVerified
        ? Icons.verified_rounded
        : isRejected
        ? Icons.error_outline_rounded
        : Icons.verified_user_outlined;

    final String title = isVerified
        ? 'Identity verified'
        : isRejected
        ? 'Verification failed'
        : 'Verification pending';
    final String subtitle = isVerified
        ? 'You’re all set to continue.'
        : isRejected
        ? 'Please re-upload your document to verify.'
        : 'Your profile photo will update once verification completes.';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: accent, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppTheme.ink,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: accent.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Text(
                        normalized.toUpperCase(),
                        style: TextStyle(
                          color: accent,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontSize: 13,
                    height: 1.35,
                    color: AppTheme.inkMuted,
                  ),
                ),
                if (isPending || isRejected) ...[
                  const SizedBox(height: 8),
                  Text(
                    'You can update your ID anytime.',
                    style: TextStyle(
                      color: accent.withValues(alpha: 0.85),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    final d = widget.initialProfileData;
    _firstNameController.text = (d['first_name'] ?? '').toString();
    _lastNameController.text = (d['last_name'] ?? '').toString();
    _mobileController.text = (d['mobile_number'] ?? '').toString();
    _dobController.text = _normalizeDobForDisplay((d['dob'] ?? '').toString());
    _heightController.text = (d['height_cm'] ?? '').toString();
    _weightController.text = (d['weight_kg'] ?? '').toString();
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _mobileController.dispose();
    _dobController.dispose();
    _heightController.dispose();
    _weightController.dispose();
    super.dispose();
  }

  Future<void> _pickDob() async {
    final initial =
        _parseDisplayDate(_dobController.text.trim()) ??
        DateTime.now().subtract(const Duration(days: 365 * 25));
    final minDate = DateTime(1900, 1, 1);
    final maxDate = DateTime.now();

    if (Platform.isIOS) {
      DateTime tempPicked = initial;
      await showCupertinoModalPopup<void>(
        context: context,
        builder: (ctx) {
          return Container(
            height: 300,
            color: CupertinoColors.systemBackground.resolveFrom(ctx),
            child: Column(
              children: [
                Container(
                  height: 44,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Done'),
                  ),
                ),
                Expanded(
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.date,
                    initialDateTime: initial,
                    minimumDate: minDate,
                    maximumDate: maxDate,
                    onDateTimeChanged: (date) {
                      tempPicked = date;
                      _dobController.text = _toDisplayDate(date);
                    },
                  ),
                ),
              ],
            ),
          );
        },
      );
      setState(() => _dobController.text = _toDisplayDate(tempPicked));
      return;
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: minDate,
      lastDate: maxDate,
    );
    if (picked != null) {
      setState(() => _dobController.text = _toDisplayDate(picked));
    }
  }

  Future<void> _save() async {
    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final mobileNumber = _mobileController.text.trim();
    final dobInput = _dobController.text.trim();
    final heightCm = _heightController.text.trim();
    final weightKg = _weightController.text.trim();

    if (firstName.isEmpty ||
        lastName.isEmpty ||
        mobileNumber.isEmpty ||
        dobInput.isEmpty ||
        heightCm.isEmpty ||
        weightKg.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all profile fields.')),
      );
      return;
    }

    if (!_isValidMobileNumber(mobileNumber)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a valid mobile number (10-15 digits).'),
        ),
      );
      return;
    }

    final dob = _formatDateForApi(dobInput);
    if (dob == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('DOB must be in DD/MM/YYYY format.')),
      );
      return;
    }

    setState(() => _saving = true);
    final res = await widget.userApiService.updateProfile(
      firstName: firstName,
      lastName: lastName,
      mobileNumber: mobileNumber,
      dob: dob,
      heightCm: heightCm,
      weightKg: weightKg,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          res.ok
              ? 'Profile updated.'
              : (res.message ?? 'Profile update failed'),
        ),
      ),
    );
    if (res.ok) {
      await widget.onCompleted();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Complete your profile'),
        actions: [
          IconButton(
            tooltip: 'Logout',
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: _ResponsivePageContainer(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const SizedBox(height: 6),
              const Text(
                'Please complete all required details to continue.',
                style: TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.only(bottom: 0),
                child: _buildIdentityStatusBanner(),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _firstNameController,
                decoration: const InputDecoration(labelText: 'First name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _lastNameController,
                decoration: const InputDecoration(labelText: 'Last name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _mobileController,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(15),
                ],
                maxLength: 15,
                maxLengthEnforcement: MaxLengthEnforcement.enforced,
                decoration: const InputDecoration(
                  labelText: 'Mobile number',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _dobController,
                readOnly: true,
                onTap: _pickDob,
                decoration: const InputDecoration(
                  labelText: 'DOB (DD/MM/YYYY)',
                  suffixIcon: Icon(Icons.calendar_today_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _heightController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Height (cm)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _weightController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Weight (kg)'),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const BmiLoader(size: 20, strokeWidth: 2)
                    : const Text('Save and Continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

DateTime? _parseDisplayDate(String input) {
  final parts = input.split('/');
  if (parts.length != 3) return null;
  final day = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final year = int.tryParse(parts[2]);
  if (day == null || month == null || year == null) return null;
  if (day < 1 || day > 31 || month < 1 || month > 12 || year < 1900) {
    return null;
  }
  return DateTime(year, month, day);
}

String _toDisplayDate(DateTime date) {
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');
  final year = date.year.toString().padLeft(4, '0');
  return '$day/$month/$year';
}

String _normalizeDobForDisplay(String input) {
  final value = input.trim();
  if (value.isEmpty) return '';
  if (_parseDisplayDate(value) != null) return value;
  final parts = value.split('-');
  if (parts.length == 3) {
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year != null &&
        month != null &&
        day != null &&
        year >= 1900 &&
        month >= 1 &&
        month <= 12 &&
        day >= 1 &&
        day <= 31) {
      return _toDisplayDate(DateTime(year, month, day));
    }
  }
  return value;
}

String? _formatDateForApi(String displayDate) {
  final raw = displayDate.trim();
  final match = RegExp(r'^(\d{2})/(\d{2})/(\d{4})$').firstMatch(raw);
  if (match == null) return null;
  final day = int.tryParse(match.group(1)!);
  final month = int.tryParse(match.group(2)!);
  final year = int.tryParse(match.group(3)!);
  if (day == null || month == null || year == null) return null;
  if (month < 1 || month > 12) return null;
  if (day < 1 || day > 31) return null;
  return '${match.group(3)}-${match.group(2)}-${match.group(1)}';
}

bool _isValidMobileNumber(String raw) {
  final normalized = raw.replaceAll(RegExp(r'\s+'), '');
  return RegExp(r'^\d{10,15}$').hasMatch(normalized);
}

class _ResponsivePageContainer extends StatelessWidget {
  const _ResponsivePageContainer({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isTablet = size.shortestSide >= 600;
    final topInset = MediaQuery.paddingOf(context).top;
    final topSpacing = (isTablet ? 24.0 : 12.0) + (topInset > 0 ? 4.0 : 0.0);

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: isTablet ? 760 : 560),
      child: Padding(
        padding: EdgeInsets.only(top: topSpacing),
        child: child,
      ),
    );
  }
}
