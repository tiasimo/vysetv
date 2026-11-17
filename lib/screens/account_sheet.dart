import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/layout.dart';
import '../core/theme.dart';
import '../data/account.dart';
import '../widgets/common.dart';

/// Sign in or create an account: a dialog on wide screens, a full-height sheet on phones.
Future<void> showAccountSheet(BuildContext context, {bool register = false, bool changePassword = false}) {
  final body = _AccountForm(register: register, changePassword: changePassword);
  if (Layout.isPhone(context)) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF0B0D16),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(child: body),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .65),
    builder: (context) => Dialog(
      backgroundColor: const Color(0xFF0B0D16),
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: VyseColors.stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(child: body),
      ),
    ),
  );
}

class _AccountForm extends StatefulWidget {
  const _AccountForm({required this.register, required this.changePassword});
  final bool register;
  final bool changePassword;

  @override
  State<_AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends State<_AccountForm> {
  late bool _register = widget.register;
  final _identity = TextEditingController(); // sign in: email or username
  final _email = TextEditingController();
  final _username = TextEditingController();
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _current = TextEditingController(); // change password: the current one
  bool _showPassword = false;
  bool _busy = false;
  String? _error;

  // forgot password: 0 = off, 1 = ask for the email, 2 = enter the code and a new password
  int _reset = 0;
  final _code = TextEditingController();
  Timer? _resendTimer;
  int _resendIn = 0;
  bool _resent = false;

  /// Signed in and changing the password (not in the forgot-password steps).
  bool get _change => widget.changePassword && _reset == 0;

  // live username check
  Timer? _check;
  String? _usernameNote; // null = nothing to say yet
  bool _usernameOk = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _username.addListener(_onUsername);
    for (final c in [_identity, _email, _name, _password, _code, _current]) {
      c.addListener(() {
        if (_error != null) setState(() => _error = null);
      });
    }
  }

  @override
  void dispose() {
    _check?.cancel();
    _resendTimer?.cancel();
    for (final c in [_identity, _email, _username, _name, _password, _code, _current]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onUsername() {
    final v = _username.text.trim().toLowerCase();
    _check?.cancel();
    if (v.isEmpty) {
      setState(() {
        _usernameNote = null;
        _usernameOk = false;
        _checking = false;
      });
      return;
    }
    if (!RegExp(r'^[a-z0-9_.]{3,20}$').hasMatch(v)) {
      setState(() {
        _usernameNote = v.length < 3 ? 'Almeno 3 caratteri' : 'Solo lettere, numeri, _ e . (massimo 20)';
        _usernameOk = false;
        _checking = false;
      });
      return;
    }
    setState(() => _checking = true);
    _check = Timer(const Duration(milliseconds: 400), () async {
      final problem = await Account.usernameProblem(v);
      if (!mounted || _username.text.trim().toLowerCase() != v) return;
      setState(() {
        _checking = false;
        _usernameOk = problem == null || problem == 'unknown';
        _usernameNote = switch (problem) {
          null => '@$v è libero',
          'unknown' => "Impossibile controllare @$v ora",
          'reserved' => "Non è disponibile",
          _ => '@$v è già preso',
        };
      });
    });
  }

  bool get _canSubmit {
    if (_busy) return false;
    if (_reset == 1) return _identity.text.trim().isNotEmpty;
    if (_reset == 2) return _code.text.length == 6 && _password.text.length >= 8;
    if (_change) return _current.text.isNotEmpty && _password.text.length >= 8;
    if (_register) {
      return _email.text.contains('@') && _usernameOk && _password.text.length >= 8;
    }
    return _identity.text.trim().isNotEmpty && _password.text.isNotEmpty;
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    if (_reset > 0) return _submitReset();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_change) {
        await Account.changePassword(_current.text, _password.text);
      } else if (_register) {
        await Account.register(email: _email.text, username: _username.text, name: _name.text, password: _password.text);
      } else {
        await Account.signIn(_identity.text, _password.text);
      }
      if (!mounted) return;
      final u = Account.user.value;
      Navigator.of(context).pop();
      if (u != null) {
        showToast(
          context,
          Text(
            _change ? 'Password cambiata' : (_register ? 'Benvenuto in Lorewatch, @${u.username}' : 'Accesso eseguito come @${u.username}'),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          icon: Icons.check_circle_rounded,
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = Account.describe(e, signingIn: !_register && !_change));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _switch(bool register) => setState(() {
    _register = register;
    _reset = 0;
    _error = null;
  });

  void _startReset() => setState(() {
    if (widget.changePassword) _identity.text = Account.user.value?.email ?? '';
    _reset = 1;
    _register = false;
    _error = null;
  });

  void _cooldown() {
    _resendTimer?.cancel();
    setState(() => _resendIn = 60);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _resendIn--);
      if (_resendIn <= 0) t.cancel();
    });
  }

  Future<void> _submitReset() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_reset == 1) {
        await Account.requestPasswordReset(_identity.text);
        if (!mounted) return;
        _code.clear();
        _password.clear();
        setState(() {
          _reset = 2;
          _resent = false;
        });
        _cooldown();
      } else {
        await Account.resetPassword(_identity.text, _code.text, _password.text);
        if (!mounted) return;
        final u = Account.user.value;
        Navigator.of(context).pop();
        showToast(
          context,
          Text(
            u == null ? 'Password cambiata' : 'Password cambiata · accesso come @${u.username}',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          icon: Icons.check_circle_rounded,
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = Account.describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    if (_resendIn > 0 || _busy) return;
    _cooldown();
    try {
      await Account.requestPasswordReset(_identity.text);
      if (mounted) setState(() => _resent = true);
    } catch (e) {
      if (mounted) setState(() => _error = Account.describe(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(phone ? 20 : 30, phone ? 14 : 26, phone ? 20 : 30, phone ? 22 : 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (phone)
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: .2), borderRadius: BorderRadius.circular(2)),
              ),
            ),
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  gradient: LinearGradient(colors: [VyseColors.accent, VyseColors.accent.withValues(alpha: .55)]),
                  boxShadow: [BoxShadow(color: VyseColors.accent.withValues(alpha: .35), blurRadius: 16)],
                ),
                child: const Icon(Icons.person_rounded, color: Colors.black),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Text(
                        _reset > 0 ? 'Reimposta la password' : (_change ? 'Cambia password' : (_register ? 'Crea il tuo account' : 'Bentornato')),
                        key: ValueKey('$_register$_reset'),
                        style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900, letterSpacing: -.4),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(switch (_reset) {
                      1 => "Ti invieremo via email un codice di 6 cifre.",
                      2 => 'Se l\'account esiste, è in arrivo un codice alla sua email.',
                      _ when _change => 'Gli altri tuoi dispositivi verranno disconnessi.',
                      _ => _register ? 'La tua lista, la cronologia e il profilo su ogni dispositivo.' : 'Accedi per riprendere da dove eri rimasto.',
                    }, style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
                  ],
                ),
              ),
              if (!phone)
                IconButton(
                  tooltip: 'Chiudi',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, color: VyseColors.textDim),
                ),
            ],
          ),
          const SizedBox(height: 20),
          if (_reset == 0 && !widget.changePassword) ...[_ModeSwitch(register: _register, onChanged: _switch), const SizedBox(height: 18)],
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_reset == 2) ...[
                  _Field(
                    controller: _code,
                    label: 'Codice',
                    hint: 'Le 6 cifre dell\'email',
                    icon: Icons.pin_outlined,
                    keyboard: TextInputType.number,
                    autofocus: true,
                    formatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                    onSubmit: _submit,
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _resendIn > 0 ? null : _resend,
                      child: Text(
                        _resendIn > 0 ? (_resent ? 'Nuovo codice inviato · rinvia tra ${_resendIn}s' : 'Rinvia il codice tra ${_resendIn}s') : 'Rinvia il codice',
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _resendIn > 0 ? VyseColors.textFaint : VyseColors.accent),
                      ),
                    ),
                  ),
                ] else if (_change)
                  _Field(
                    controller: _current,
                    label: 'Password attuale',
                    hint: 'La tua password',
                    icon: Icons.lock_outline_rounded,
                    obscure: !_showPassword,
                    autofocus: true,
                    onSubmit: _submit,
                  )
                else if (_register) ...[
                  _Field(controller: _name, label: 'Nome visualizzato', hint: 'Quello che vedono gli amici', icon: Icons.badge_outlined, onSubmit: _submit),
                  const SizedBox(height: 12),
                  _Field(
                    controller: _username,
                    label: 'Nome utente',
                    hint: 'Scegli qualcosa di unico',
                    icon: Icons.alternate_email_rounded,
                    onSubmit: _submit,
                    lowercase: true,
                    trailing: _checking
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.textDim))
                        : (_usernameNote == null
                              ? null
                              : Icon(
                                  _usernameOk ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                                  size: 19,
                                  color: _usernameOk ? const Color(0xFF3DDC97) : const Color(0xFFFF8A8C),
                                )),
                  ),
                  if (_usernameNote != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                      child: Text(_usernameNote!, style: TextStyle(fontSize: 12, color: _usernameOk ? const Color(0xFF3DDC97) : const Color(0xFFFF8A8C))),
                    ),
                  const SizedBox(height: 12),
                  _Field(
                    controller: _email,
                    label: 'Email',
                    hint: 'you@example.com',
                    icon: Icons.mail_outline_rounded,
                    keyboard: TextInputType.emailAddress,
                    onSubmit: _submit,
                  ),
                ] else
                  _Field(
                    controller: _identity,
                    label: 'Email o nome utente',
                    hint: 'La tua email o nome utente',
                    icon: Icons.person_outline_rounded,
                    keyboard: TextInputType.emailAddress,
                    autofocus: !phone || _reset == 1,
                    onSubmit: _submit,
                  ),
                if (_reset != 1) ...[
                  if (_reset == 0) const SizedBox(height: 12),
                  _Field(
                    controller: _password,
                    label: _reset == 2 || _change ? 'Nuova password' : 'Password',
                    hint: _register || _reset == 2 || _change ? 'Almeno 8 caratteri' : 'La tua password',
                    icon: Icons.lock_outline_rounded,
                    obscure: !_showPassword,
                    onSubmit: _submit,
                    trailing: IconButton(
                      tooltip: _showPassword ? 'Nascondi password' : 'Mostra password',
                      onPressed: () => setState(() => _showPassword = !_showPassword),
                      icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 19, color: VyseColors.textDim),
                    ),
                  ),
                  if ((_register || _reset == 2 || _change) && _password.text.isNotEmpty && _password.text.length < 8)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(4, 6, 4, 0),
                      child: Text('Almeno 8 caratteri', style: TextStyle(fontSize: 12, color: VyseColors.textDim)),
                    ),
                  if (!_register && _reset == 0)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _startReset,
                        child: Text(
                          _change ? 'Hai dimenticato la password attuale?' : 'Password dimenticata?',
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: VyseColors.textDim),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            child: _error == null
                ? const SizedBox(width: double.infinity)
                : Container(
                    margin: const EdgeInsets.only(top: 14),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: const Color(0xFFFF4D4F).withValues(alpha: .12),
                      border: Border.all(color: const Color(0xFFFF4D4F).withValues(alpha: .3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline_rounded, size: 18, color: Color(0xFFFF8A8C)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _error!,
                            style: const TextStyle(fontSize: 13, color: Color(0xFFFFB3B4), fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 20),
          ListenableBuilder(
            listenable: Listenable.merge([_identity, _email, _password, _code, _current]),
            builder: (context, _) => _Submit(
              label: switch (_reset) {
                1 => 'Invia codice',
                2 => 'Imposta nuova password',
                _ when _change => 'Cambia password',
                _ => _register ? 'Crea account' : 'Accedi',
              },
              busy: _busy,
              enabled: _canSubmit,
              onTap: _submit,
            ),
          ),
          if (!_change) ...[
            const SizedBox(height: 14),
            Center(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    _reset > 0 ? 'Te la sei ricordata?' : (_register ? 'Hai già un account?' : 'Nuovo su Lorewatch?'),
                    style: const TextStyle(fontSize: 13, color: VyseColors.textDim),
                  ),
                  TextButton(
                    onPressed: () => _switch(_reset > 0 ? false : !_register),
                    child: Text(
                      _reset > 0 ? (widget.changePassword ? 'Indietro' : 'Torna all\'accesso') : (_register ? 'Accedi' : 'Creane uno'),
                      style: const TextStyle(fontWeight: FontWeight.w800, color: VyseColors.accent),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.register, required this.onChanged});
  final bool register;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    height: 44,
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: .05), borderRadius: BorderRadius.circular(14)),
    child: LayoutBuilder(
      builder: (context, c) => Stack(
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: register ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: c.maxWidth / 2,
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: .14), borderRadius: BorderRadius.circular(10)),
            ),
          ),
          Row(
            children: [
              for (final (v, label) in const [(false, 'Accedi'), (true, 'Crea account')])
                Expanded(
                  child: Pressable(
                    onTap: () => onChanged(v),
                    builder: (context, hovered, _) => Center(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: register == v ? Colors.white : (hovered ? VyseColors.text : VyseColors.textDim),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    required this.onSubmit,
    this.obscure = false,
    this.keyboard,
    this.trailing,
    this.autofocus = false,
    this.lowercase = false,
    this.formatters,
  });
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final VoidCallback onSubmit;
  final bool obscure;
  final TextInputType? keyboard;
  final Widget? trailing;
  final bool autofocus;
  final bool lowercase;
  final List<TextInputFormatter>? formatters;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6),
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: VyseColors.textDim),
        ),
      ),
      TextField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboard,
        autofocus: autofocus,
        autocorrect: false,
        inputFormatters: formatters,
        enableSuggestions: !obscure && !lowercase,
        textInputAction: TextInputAction.next,
        onSubmitted: (_) => onSubmit(),
        onChanged: lowercase
            ? (v) {
                final low = v.toLowerCase();
                if (low != v) {
                  controller.value = controller.value.copyWith(
                    text: low,
                    selection: TextSelection.collapsed(offset: low.length),
                  );
                }
              }
            : null,
        style: const TextStyle(fontSize: 14.5),
        cursorColor: VyseColors.accent,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: VyseColors.textFaint, fontSize: 14),
          prefixIcon: Icon(icon, size: 19, color: VyseColors.textFaint),
          suffixIcon: trailing == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Center(widthFactor: 1, child: trailing),
                ),
          filled: true,
          fillColor: Colors.white.withValues(alpha: .05),
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: .06)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: VyseColors.accent.withValues(alpha: .7), width: 1.5),
          ),
        ),
      ),
    ],
  );
}

class _Submit extends StatelessWidget {
  const _Submit({required this.label, required this.busy, required this.enabled, required this.onTap});
  final String label;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: enabled ? onTap : null,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed && enabled ? .98 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 50,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: enabled || busy ? (hovered ? Colors.white : Colors.white.withValues(alpha: .93)) : Colors.white.withValues(alpha: .1),
          boxShadow: [if (enabled && hovered) BoxShadow(color: Colors.white.withValues(alpha: .2), blurRadius: 18)],
        ),
        child: busy
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.black))
            : Text(
                label,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: enabled ? Colors.black : VyseColors.textFaint),
              ),
      ),
    ),
  );
}
