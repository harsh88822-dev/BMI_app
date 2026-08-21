import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/bmi_loader.dart';

/// Normalizes common password keyboard quirks (e.g. fullwidth digits ０-９ → 0-9).
class _NormalizePasswordInputFormatter extends TextInputFormatter {
  const _NormalizePasswordInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final normalized = _normalizePasswordCharacters(newValue.text);
    if (normalized == newValue.text) return newValue;

    final selectionIndex = normalized.length.clamp(0, normalized.length);
    return TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: selectionIndex),
      composing: TextRange.empty,
    );
  }
}

String _normalizePasswordCharacters(String input) {
  final buffer = StringBuffer();
  for (final unit in input.codeUnits) {
    // Fullwidth digits ０-９ → 0-9
    if (unit >= 0xFF10 && unit <= 0xFF19) {
      buffer.writeCharCode(0x30 + (unit - 0xFF10));
      continue;
    }
    // Fullwidth Latin A-Z / a-z
    if (unit >= 0xFF21 && unit <= 0xFF3A) {
      buffer.writeCharCode(0x41 + (unit - 0xFF21));
      continue;
    }
    if (unit >= 0xFF41 && unit <= 0xFF5A) {
      buffer.writeCharCode(0x61 + (unit - 0xFF41));
      continue;
    }
    // Fullwidth @ ＠
    if (unit == 0xFF20) {
      buffer.write('@');
      continue;
    }
    buffer.writeCharCode(unit);
  }
  return buffer.toString();
}

bool _hasAsciiDigit(String value) {
  for (final unit in value.codeUnits) {
    if (unit >= 0x30 && unit <= 0x39) return true;
  }
  return false;
}

bool _hasUppercaseLetter(String value) {
  for (final unit in value.codeUnits) {
    if (unit >= 0x41 && unit <= 0x5A) return true;
  }
  return false;
}

bool _hasLowercaseLetter(String value) {
  for (final unit in value.codeUnits) {
    if (unit >= 0x61 && unit <= 0x7A) return true;
  }
  return false;
}

bool _hasSpecialCharacter(String value) {
  const specials = '!@#\$%^&*(),.?":{}|<>_-+/=~`[]\\;\'';
  for (final ch in value.split('')) {
    if (specials.contains(ch)) return true;
  }
  // Accept any non-alphanumeric character as special.
  return RegExp(r'[^A-Za-z0-9]').hasMatch(value);
}

void _presentAuthSnackBar(
  BuildContext context,
  String message, {
  required bool isError,
}) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      content: Text(message),
      backgroundColor: isError ? scheme.error : const Color(0xFF2C3E38),
    ),
  );
}

const String kAuthHeaderLogoPath =
    'assets/logo-removebg-preview-5608ed11-2dc5-4338-a1bc-1aa9201ad955.png';

enum AuthStep {
  login,
  register,
  verifyRegistrationOtp,
  forgotPassword,
  resetPasswordOtp,
}

class AuthFlow extends StatefulWidget {
  const AuthFlow({super.key, required this.onAuthenticated});

  final ValueChanged<String> onAuthenticated;

  @override
  State<AuthFlow> createState() => _AuthFlowState();
}

class _AuthFlowState extends State<AuthFlow> {
  final AuthApiService _authApiService = AuthApiService();

  AuthStep _step = AuthStep.login;
  String _emailContext = '';

  void _goTo(AuthStep step) {
    setState(() {
      _step = step;
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case AuthStep.login:
        return LoginScreen(
          authApiService: _authApiService,
          onLoginSuccess: widget.onAuthenticated,
          onRegisterTap: () => _goTo(AuthStep.register),
          onForgotPasswordTap: () => _goTo(AuthStep.forgotPassword),
          onVerificationRequired: (String email) {
            setState(() {
              _emailContext = email;
              _step = AuthStep.verifyRegistrationOtp;
            });
          },
        );
      case AuthStep.register:
        return RegisterScreen(
          authApiService: _authApiService,
          onBackToLogin: () => _goTo(AuthStep.login),
          onOtpRequired: (String email) {
            setState(() {
              _emailContext = email;
              _step = AuthStep.verifyRegistrationOtp;
            });
          },
        );
      case AuthStep.verifyRegistrationOtp:
        return VerifyOtpScreen(
          authApiService: _authApiService,
          title: 'Verify Account',
          description: 'Enter the OTP sent to $_emailContext',
          email: _emailContext,
          isResetFlow: false,
          onBack: () => _goTo(AuthStep.login),
          onVerified: (String? token) {
            if (token != null && token.isNotEmpty) {
              widget.onAuthenticated(token);
              return;
            }
            _goTo(AuthStep.login);
          },
        );
      case AuthStep.forgotPassword:
        return ForgotPasswordScreen(
          authApiService: _authApiService,
          onBackToLogin: () => _goTo(AuthStep.login),
          onOtpRequired: (String email) {
            setState(() {
              _emailContext = email;
              _step = AuthStep.resetPasswordOtp;
            });
          },
        );
      case AuthStep.resetPasswordOtp:
        return VerifyOtpScreen(
          authApiService: _authApiService,
          title: 'Reset Password',
          description: 'Enter OTP and set a new password for $_emailContext',
          email: _emailContext,
          isResetFlow: true,
          onBack: () => _goTo(AuthStep.login),
          onVerified: (_) => _goTo(AuthStep.login),
        );
    }
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.authApiService,
    required this.onLoginSuccess,
    required this.onRegisterTap,
    required this.onForgotPasswordTap,
    required this.onVerificationRequired,
  });

  final AuthApiService authApiService;
  final ValueChanged<String> onLoginSuccess;
  final VoidCallback onRegisterTap;
  final VoidCallback onForgotPasswordTap;
  final ValueChanged<String> onVerificationRequired;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    final response = await widget.authApiService.login(
      email: _emailController.text.trim(),
      password: _normalizePasswordCharacters(_passwordController.text.trim()),
    );
    if (!mounted) return;
    setState(() => _loading = false);
    if (!response.ok && _isVerificationPendingError(response.message)) {
      _showMessage(
        'Account exists but email is not verified. Please verify OTP.',
        isError: true,
      );
      widget.onVerificationRequired(_emailController.text.trim());
      return;
    }

    _showMessage(response.message, isError: !response.ok);
    if (response.ok) {
      final token = response.token;
      if (token == null || token.isEmpty) {
        _showMessage(
          'Login succeeded but token was missing in response.',
          isError: true,
        );
        return;
      }
      widget.onLoginSuccess(token);
    }
  }

  bool _isVerificationPendingError(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('verify') &&
        (normalized.contains('otp') || normalized.contains('email'));
  }

  void _showMessage(String message, {bool isError = false}) {
    _presentAuthSnackBar(context, message, isError: isError);
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Welcome back',
      subtitle: 'Sign in to continue with Clockwork BMI',
      headerLogoAssetPath: kAuthHeaderLogoPath,
      child: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          children: [
            AuthTextField(
              controller: _emailController,
              label: 'Email',
              keyboardType: TextInputType.emailAddress,
              validator: _emailValidator,
            ),
            const SizedBox(height: 12),
            AuthTextField(
              controller: _passwordController,
              label: 'Password',
              obscureText: true,
              keyboardType: TextInputType.visiblePassword,
              inputFormatters: const [_NormalizePasswordInputFormatter()],
              validator: (value) {
                final raw = value?.trim() ?? '';
                if (raw.isEmpty) return 'Password is required';
                return null;
              },
            ),
            const SizedBox(height: 20),
            AuthPrimaryButton(
              label: 'Login',
              loading: _loading,
              onPressed: _submit,
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: widget.onForgotPasswordTap,
              child: const Text('Forgot password?'),
            ),
            TextButton(
              onPressed: widget.onRegisterTap,
              child: const Text('Create an account'),
            ),
          ],
        ),
      ),
    );
  }
}

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({
    super.key,
    required this.authApiService,
    required this.onOtpRequired,
    required this.onBackToLogin,
  });

  final AuthApiService authApiService;
  final ValueChanged<String> onOtpRequired;
  final VoidCallback onBackToLogin;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    final response = await widget.authApiService.register(
      email: _emailController.text.trim(),
      password: _normalizePasswordCharacters(_passwordController.text.trim()),
    );
    if (!mounted) return;
    setState(() => _loading = false);
    _showMessage(response.message, isError: !response.ok);
    if (response.ok) {
      widget.onOtpRequired(_emailController.text.trim());
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    _presentAuthSnackBar(context, message, isError: isError);
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Create Account',
      subtitle: 'Sign up with your email',
      headerLogoAssetPath: kAuthHeaderLogoPath,
      child: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          children: [
            AuthTextField(
              controller: _emailController,
              label: 'Email',
              keyboardType: TextInputType.emailAddress,
              validator: _emailValidator,
            ),
            const SizedBox(height: 12),
            AuthTextField(
              controller: _passwordController,
              label: 'Password',
              obscureText: true,
              keyboardType: TextInputType.visiblePassword,
              inputFormatters: const [_NormalizePasswordInputFormatter()],
              validator: _passwordValidator,
            ),
            const SizedBox(height: 8),
            _PasswordRequirements(password: _passwordController.text),
            const SizedBox(height: 12),
            AuthTextField(
              controller: _confirmPasswordController,
              label: 'Confirm Password',
              obscureText: true,
              keyboardType: TextInputType.visiblePassword,
              inputFormatters: const [_NormalizePasswordInputFormatter()],
              validator: (String? value) {
                final confirm = _normalizePasswordCharacters(
                  value?.trim() ?? '',
                );
                if (confirm.isEmpty) {
                  return 'Please confirm password';
                }
                if (confirm !=
                    _normalizePasswordCharacters(
                      _passwordController.text.trim(),
                    )) {
                  return 'Passwords do not match';
                }
                return null;
              },
            ),
            const SizedBox(height: 20),
            AuthPrimaryButton(
              label: 'Register',
              loading: _loading,
              onPressed: _submit,
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: widget.onBackToLogin,
              child: const Text('Back to login'),
            ),
          ],
        ),
      ),
    );
  }
}

class VerifyOtpScreen extends StatefulWidget {
  const VerifyOtpScreen({
    super.key,
    required this.authApiService,
    required this.title,
    required this.description,
    required this.email,
    required this.isResetFlow,
    required this.onBack,
    required this.onVerified,
  });

  final AuthApiService authApiService;
  final String title;
  final String description;
  final String email;
  final bool isResetFlow;
  final VoidCallback onBack;
  final ValueChanged<String?> onVerified;

  @override
  State<VerifyOtpScreen> createState() => _VerifyOtpScreenState();
}

class _VerifyOtpScreenState extends State<VerifyOtpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _otpController = TextEditingController();
  final _newPasswordController = TextEditingController();
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _newPasswordController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _otpController.dispose();
    _newPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    final response = widget.isResetFlow
        ? await widget.authApiService.resetPassword(
            email: widget.email,
            otp: _otpController.text.trim(),
            newPassword: _normalizePasswordCharacters(
              _newPasswordController.text.trim(),
            ),
          )
        : await widget.authApiService.verifyOtp(
            email: widget.email,
            otp: _otpController.text.trim(),
          );
    if (!mounted) return;
    setState(() => _loading = false);
    _showMessage(response.message, isError: !response.ok);
    if (response.ok) {
      widget.onVerified(response.token);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    _presentAuthSnackBar(context, message, isError: isError);
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: widget.title,
      subtitle: widget.description,
      child: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          children: [
            AuthTextField(
              controller: _otpController,
              label: 'OTP',
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              validator: (String? value) {
                final raw = value?.trim() ?? '';
                if (raw.length != 6) {
                  return 'OTP must be 6 digits';
                }
                return null;
              },
            ),
            if (widget.isResetFlow) ...[
              const SizedBox(height: 12),
              AuthTextField(
                controller: _newPasswordController,
                label: 'New Password',
                obscureText: true,
                keyboardType: TextInputType.visiblePassword,
                inputFormatters: const [_NormalizePasswordInputFormatter()],
                validator: _passwordValidator,
              ),
              const SizedBox(height: 8),
              _PasswordRequirements(password: _newPasswordController.text),
            ],
            const SizedBox(height: 20),
            AuthPrimaryButton(
              label: widget.isResetFlow ? 'Reset Password' : 'Verify OTP',
              loading: _loading,
              onPressed: _submit,
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: widget.onBack,
              child: const Text('Back to login'),
            ),
          ],
        ),
      ),
    );
  }
}

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({
    super.key,
    required this.authApiService,
    required this.onBackToLogin,
    required this.onOtpRequired,
  });

  final AuthApiService authApiService;
  final VoidCallback onBackToLogin;
  final ValueChanged<String> onOtpRequired;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    final email = _emailController.text.trim();
    final response = await widget.authApiService.forgotPassword(email: email);
    if (!mounted) return;
    setState(() => _loading = false);
    _showMessage(response.message, isError: !response.ok);
    if (response.ok) {
      widget.onOtpRequired(email);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    _presentAuthSnackBar(context, message, isError: isError);
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Forgot Password',
      subtitle: 'We will send an OTP to your email',
      child: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          children: [
            AuthTextField(
              controller: _emailController,
              label: 'Email',
              keyboardType: TextInputType.emailAddress,
              validator: _emailValidator,
            ),
            const SizedBox(height: 20),
            AuthPrimaryButton(
              label: 'Send OTP',
              loading: _loading,
              onPressed: _submit,
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: widget.onBackToLogin,
              child: const Text('Back to login'),
            ),
          ],
        ),
      ),
    );
  }
}

class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.headerLogoAssetPath,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final String? headerLogoAssetPath;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isTablet = size.shortestSide >= 600;
    final topInset = MediaQuery.paddingOf(context).top;
    final topSpacing = (isTablet ? 24.0 : 12.0) + (topInset > 0 ? 4.0 : 0.0);

    return Scaffold(
      backgroundColor: AppTheme.parchment,
      body: SafeArea(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppTheme.parchment,
                Color.lerp(AppTheme.parchment, AppTheme.deepBlue, 0.045)!,
                AppTheme.parchment,
              ],
              stops: const [0.0, 0.5, 1.0],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                isTablet ? 36 : 22,
                (isTablet ? 28 : 18) + topSpacing,
                isTablet ? 36 : 22,
                isTablet ? 32 : 24,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: isTablet ? 620 : 460),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.ink.withValues(alpha: 0.07),
                        blurRadius: 48,
                        offset: const Offset(0, 22),
                      ),
                      BoxShadow(
                        color: AppTheme.ink.withValues(alpha: 0.03),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Card(
                    elevation: 0,
                    margin: EdgeInsets.zero,
                    color: Colors.white,
                    surfaceTintColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                      side: BorderSide(
                        color: AppTheme.divider.withValues(alpha: 0.75),
                      ),
                    ),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        isTablet ? 32 : 22,
                        isTablet ? 30 : 22,
                        isTablet ? 32 : 22,
                        isTablet ? 28 : 22,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (headerLogoAssetPath != null)
                            Center(
                              child: SizedBox(
                                height: isTablet ? 88 : 76,
                                child: Image.asset(
                                  headerLogoAssetPath!,
                                  fit: BoxFit.contain,
                                  errorBuilder: (context, error, stackTrace) {
                                    return const SizedBox.shrink();
                                  },
                                ),
                              ),
                            ),
                          if (headerLogoAssetPath != null)
                            SizedBox(height: isTablet ? 18 : 14),
                          SizedBox(
                            width: double.infinity,
                            child: Text(
                              title,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(
                                    fontSize: isTablet ? 34 : null,
                                    fontWeight: FontWeight.w600,
                                    height: 1.12,
                                  ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: Text(
                              subtitle,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: AppTheme.inkMuted,
                                    height: 1.4,
                                  ),
                            ),
                          ),
                          const SizedBox(height: 26),
                          child,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AuthPrimaryButton extends StatelessWidget {
  const AuthPrimaryButton({
    super.key,
    required this.label,
    required this.loading,
    required this.onPressed,
  });

  final String label;
  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: loading ? null : onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: loading
              ? const BmiLoader(size: 20, strokeWidth: 2)
              : Text(label),
        ),
      ),
    );
  }
}

class AuthTextField extends StatelessWidget {
  const AuthTextField({
    super.key,
    required this.controller,
    required this.label,
    this.keyboardType,
    this.obscureText = false,
    this.validator,
    this.inputFormatters,
  });

  final TextEditingController controller;
  final String label;
  final TextInputType? keyboardType;
  final bool obscureText;
  final String? Function(String?)? validator;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscureText,
      validator: validator,
      inputFormatters: inputFormatters,
      decoration: InputDecoration(labelText: label),
    );
  }
}

String? _emailValidator(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) {
    return 'Email is required';
  }
  final emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
  if (!emailRegex.hasMatch(raw)) {
    return 'Enter a valid email address';
  }
  return null;
}

String? _passwordValidator(String? value) {
  final raw = _normalizePasswordCharacters(value?.trim() ?? '');
  if (raw.isEmpty) {
    return 'Password is required';
  }
  if (raw.length < 8) {
    return 'Password must be at least 8 characters';
  }
  if (!_hasUppercaseLetter(raw)) {
    return 'Include at least 1 uppercase letter';
  }
  if (!_hasLowercaseLetter(raw)) {
    return 'Include at least 1 lowercase letter';
  }
  if (!_hasAsciiDigit(raw)) {
    return 'Include at least 1 number';
  }
  if (!_hasSpecialCharacter(raw)) {
    return 'Include at least 1 special character';
  }
  return null;
}

class _PasswordRequirements extends StatelessWidget {
  const _PasswordRequirements({required this.password});

  final String password;

  @override
  Widget build(BuildContext context) {
    final raw = _normalizePasswordCharacters(password.trim());
    final checks = <(bool, String)>[
      (raw.length >= 8, 'At least 8 characters'),
      (_hasUppercaseLetter(raw), '1 uppercase letter (A-Z)'),
      (_hasLowercaseLetter(raw), '1 lowercase letter (a-z)'),
      (_hasAsciiDigit(raw), '1 number (0-9)'),
      (_hasSpecialCharacter(raw), '1 special character (!@#...)'),
    ];

    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final check in checks)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(
                    check.$1 ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 16,
                    color: check.$1
                        ? const Color(0xFF2E7D32)
                        : Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    check.$2,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: check.$1
                          ? const Color(0xFF2E7D32)
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: check.$1 ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
