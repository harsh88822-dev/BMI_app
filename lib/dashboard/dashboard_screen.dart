import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../measurement/measurement_prep_screen.dart';
import '../screens/height_calibration_screen.dart';
import '../services/session_storage_service.dart';
import '../services/user_api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/bmi_loader.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.onLogout});

  final Future<void> Function() onLogout;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _userApiService = UserApiService();
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _HomeTab(userApiService: _userApiService),
          const _StartBmiTab(),
          _ResultsTab(userApiService: _userApiService),
          _ProfileTab(
            userApiService: _userApiService,
            onLogout: widget.onLogout,
          ),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: AppTheme.ink.withValues(alpha: 0.06),
              blurRadius: 24,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: NavigationBar(
            height: 72,
            selectedIndex: _currentIndex,
            onDestinationSelected: (index) {
              setState(() => _currentIndex = index);
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.camera_alt_outlined),
                selectedIcon: Icon(Icons.camera_alt_rounded),
                label: 'Start BMI',
              ),
              NavigationDestination(
                icon: Icon(Icons.history_outlined),
                selectedIcon: Icon(Icons.history_rounded),
                label: 'Results',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person_rounded),
                label: 'Profile',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeTab extends StatelessWidget {
  const _HomeTab({required this.userApiService});

  final UserApiService userApiService;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final banners = <_HomeBanner>[
      const _HomeBanner(
        title: 'Get Your NHS Covid & Flu Jab',
        subtitle: 'Walk-in, no appointment needed (eligibility applies).',
        // TODO: Replace with real website image URL when finalized.
        imageUrl: null,
      ),
      const _HomeBanner(
        title: 'Pharmacy First Now Available',
        subtitle: 'Treatment without booking a GP appointment.',
        imageUrl: null,
      ),
      const _HomeBanner(
        title: 'Walk in Travel Vaccination',
        subtitle: 'Vaccines available at all stores.',
        imageUrl: null,
      ),
    ];

    final offers = <_OfferCardData>[
      _OfferCardData(
        title: 'Blood Pressure Check',
        subtitle: 'Free NHS consultation (where available).',
        imageUrl: null,
        accent: scheme.primary,
        icon: Icons.monitor_heart_outlined,
      ),
      _OfferCardData(
        title: 'Contraception Service',
        subtitle: 'Advice, repeats, and first-time pill support.',
        imageUrl: null,
        accent: scheme.secondary,
        icon: Icons.health_and_safety_outlined,
      ),
      _OfferCardData(
        title: 'Travel Vaccines',
        subtitle: 'Walk-in vaccines and antimalarials.',
        imageUrl: null,
        accent: scheme.tertiary,
        icon: Icons.flight_takeoff_outlined,
      ),
    ];

    return _ResponsiveTabContainer(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _PremiumHeader(
            title: 'Clockwork Pharmacy',
            subtitle: 'Services, offers and store locations.',
          ),
          const SizedBox(height: 14),
          _BannerCarousel(banners: banners),
          const SizedBox(height: 18),
          _SectionTitle(title: 'Our offers'),
          const SizedBox(height: 12),
          SizedBox(
            height: 148,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: offers.length,
              separatorBuilder: (context, index) => const SizedBox(width: 12),
              itemBuilder: (context, index) => _OfferCard(data: offers[index]),
            ),
          ),
          const SizedBox(height: 22),
          _SectionTitle(title: 'Our stores'),
          const SizedBox(height: 12),
          const _StoresList(),
        ],
      ),
    );
  }
}

class _HomeBanner {
  const _HomeBanner({
    required this.title,
    required this.subtitle,
    required this.imageUrl,
  });

  final String title;
  final String subtitle;
  final String? imageUrl;
}

class _BannerCarousel extends StatefulWidget {
  const _BannerCarousel({required this.banners});

  final List<_HomeBanner> banners;

  @override
  State<_BannerCarousel> createState() => _BannerCarouselState();
}

class _BannerCarouselState extends State<_BannerCarousel> {
  final PageController _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.sizeOf(context).shortestSide >= 600;
    final height = isTablet ? 220.0 : 190.0;

    return Column(
      children: [
        SizedBox(
          height: height,
          child: PageView.builder(
            controller: _controller,
            onPageChanged: (i) => setState(() => _index = i),
            itemCount: widget.banners.length,
            itemBuilder: (context, i) {
              final banner = widget.banners[i];
              return _BannerCard(banner: banner);
            },
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(widget.banners.length, (i) {
            final selected = i == _index;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: selected ? 24 : 7,
              height: 7,
              decoration: BoxDecoration(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(
                        context,
                      ).colorScheme.outline.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(999),
              ),
            );
          }),
        ),
      ],
    );
  }
}

class _BannerCard extends StatelessWidget {
  const _BannerCard({required this.banner});

  final _HomeBanner banner;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (banner.imageUrl != null)
              Image.network(
                banner.imageUrl!,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    _bannerFallback(primary),
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return _bannerFallback(primary);
                },
              )
            else
              _bannerFallback(primary),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.black.withValues(alpha: 0.55),
                    Colors.black.withValues(alpha: 0.10),
                  ],
                  begin: Alignment.bottomLeft,
                  end: Alignment.topRight,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    banner.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 20,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    banner.subtitle,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bannerFallback(Color primary) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            primary.withValues(alpha: 0.24),
            primary.withValues(alpha: 0.06),
          ],
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
        ),
      ),
      child: Center(
        child: Icon(
          Icons.local_pharmacy_outlined,
          size: 54,
          color: primary.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

class _OfferCardData {
  const _OfferCardData({
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.accent,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final String? imageUrl;
  final Color accent;
  final IconData icon;
}

class _OfferCard extends StatelessWidget {
  const _OfferCard({required this.data});

  final _OfferCardData data;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 260,
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outline.withValues(alpha: 0.65)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {},
          splashColor: data.accent.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: data.accent.withValues(alpha: 0.11),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(data.icon, color: data.accent, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        data.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        data.subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontSize: 13,
                          height: 1.25,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StoreLocation {
  const _StoreLocation({
    required this.name,
    required this.addressLines,
    required this.phone,
  });

  final String name;
  final List<String> addressLines;
  final String phone;
}

class _StoresList extends StatelessWidget {
  const _StoresList();

  static const _stores = <_StoreLocation>[
    _StoreLocation(
      name: 'Clockwork Pharmacy and Travel Clinic, 273 Caledonian Road',
      addressLines: ['273 Caledonian Road', 'Islington', 'London', 'N1 1EF'],
      phone: '0207 607 4525',
    ),
    _StoreLocation(
      name: 'Clockwork Pharmacy and Travel Clinic, 161 Caledonian Road',
      addressLines: ['161 Caledonian Road', 'Islington', 'London', 'N1 0SL'],
      phone: '0207 837 5753',
    ),
    _StoreLocation(
      name: 'Clockwork Pharmacy and Travel Clinic, 239 Well Street',
      addressLines: ['239 Well Street', 'Hackney', 'London', 'E9 6RG'],
      phone: '0208 985 4630',
    ),
    _StoreLocation(
      name: 'Clockwork Pharmacy and Travel Clinic, 236–238 Well Street',
      addressLines: ['236 - 238 Well Street', 'Hackney', 'London', 'E9 6QT'],
      phone: '0208 985 1157',
    ),
    _StoreLocation(
      name:
          'Clockwork Pharmacy and Yellow Fever Vaccination Centre, Mare Street',
      addressLines: ['398-400 Mare Street', 'Hackney', 'London', 'E8 1HP'],
      phone: '0208 985 1635',
    ),
    _StoreLocation(
      name: 'Clockwork Pharmacy and Travel Clinic, Victoria Park Road',
      addressLines: [
        '215-217 Victoria Park Road',
        'Hackney',
        'London',
        'E9 7HD',
      ],
      phone: '0208 985 1717',
    ),
    _StoreLocation(
      name: 'Clockwork Pharmacy and Travel Clinic, Barking Road',
      addressLines: ['741 Barking Rd', 'Newham', 'London', 'E13 9ER'],
      phone: '0208 472 1054',
    ),
    _StoreLocation(
      name: 'Clockwork Pharmacy and Travel Clinic, Neasden Lane',
      addressLines: ['283-285 Neasden Lane', 'Willesden', 'London', 'NW10 1QJ'],
      phone: '0208 450 7654',
    ),
    _StoreLocation(
      name:
          'Clockwork Pharmacy and Travel Clinic, Brownlow Road (Bounds Green)',
      addressLines: [
        '9 Queens Parade Brownlow Rd',
        'Haringey',
        'London',
        'N11 2DN',
      ],
      phone: '0208 888 3222',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: _stores
          .map(
            (s) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(color: scheme.outline.withValues(alpha: 0.65)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.name,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        s.addressLines.join('\n'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          height: 1.3,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Icon(
                            Icons.call_outlined,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () async {
                                final uri = Uri(
                                  scheme: 'tel',
                                  path: s.phone.replaceAll(' ', ''),
                                );
                                if (await canLaunchUrl(uri)) {
                                  await launchUrl(uri);
                                  return;
                                }
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Unable to open dialer'),
                                  ),
                                );
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Text(
                                  s.phone,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Copy phone number',
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: s.phone),
                              );
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Phone number copied'),
                                ),
                              );
                            },
                            icon: const Icon(Icons.copy_rounded, size: 18),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

class _StartBmiTab extends StatelessWidget {
  const _StartBmiTab();

  @override
  Widget build(BuildContext context) {
    return _ResponsiveTabContainer(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _PremiumHeader(
            title: 'Ready to start?',
            subtitle: 'Measure your BMI in seconds.',
          ),
          const SizedBox(height: 16),
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: BorderSide(
                color: Theme.of(
                  context,
                ).colorScheme.outline.withValues(alpha: 0.65),
              ),
            ),
            color: Colors.white,
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              splashColor: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.08),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const MeasurementPrepScreen(),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Before you begin',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Stand in a clear area with even, natural lighting.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.play_arrow_rounded),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const MeasurementPrepScreen(),
                            ),
                          );
                        },
                        label: const Text('Start Measurement'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultsTab extends StatefulWidget {
  const _ResultsTab({required this.userApiService});

  final UserApiService userApiService;

  @override
  State<_ResultsTab> createState() => _ResultsTabState();
}

class _ResultsTabState extends State<_ResultsTab> {
  late Future<ApiResult> _historyFuture;

  @override
  void initState() {
    super.initState();
    _historyFuture = widget.userApiService.getBmiHistory();
  }

  Future<void> _reload() async {
    setState(() {
      _historyFuture = widget.userApiService.getBmiHistory();
    });
    await _historyFuture;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _ResponsiveTabContainer(
      child: FutureBuilder<ApiResult>(
        future: _historyFuture,
        builder: (context, snapshot) {
          final waiting = snapshot.connectionState == ConnectionState.waiting;
          final result = snapshot.data;
          final list = result?.data is List ? result!.data as List : const [];
          final hasError = snapshot.hasError || (result != null && !result.ok);

          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                _PremiumHeader(
                  title: 'My previous BMI results',
                  subtitle: 'Your recent measurements and verification status.',
                ),
                const SizedBox(height: 16),
                if (waiting)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(
                      child: BmiLoader(showLabel: true, label: 'Loading history…'),
                    ),
                  )
                else if (hasError)
                  Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Unable to load BMI history.',
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            result?.message ?? 'Please try again.',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _reload,
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (list.isEmpty)
                  Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'No BMI history found yet. Complete your first scan to see entries here.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                else
                  ...list.map(
                    (entry) => _BmiHistoryCard(
                      entry: entry,
                      userApiService: widget.userApiService,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _BmiHistoryCard extends StatelessWidget {
  const _BmiHistoryCard({required this.entry, required this.userApiService});

  final dynamic entry;
  final UserApiService userApiService;

  @override
  Widget build(BuildContext context) {
    final map = entry is Map ? entry : const <String, dynamic>{};
    final estimatedBmi = (map['estimated_bmi'] ?? '--').toString();
    final heightDetected = (map['height_detected'] ?? '--').toString();
    final weightEstimated = (map['weight_estimated'] ?? '--').toString();
    final status = (map['status'] ?? 'unknown').toString();
    final createdAt = _formatHistoryDateTime((map['created_at'] ?? '').toString());
    final scheme = Theme.of(context).colorScheme;
    final statusColor = _historyStatusColor(status, scheme);

    final measurementId = int.tryParse((map['id'] ?? '').toString());

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: measurementId == null
            ? null
            : () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => _BmiHistoryDetailPage(
                      measurementId: measurementId,
                      userApiService: userApiService,
                    ),
                  ),
                );
              },
        child: Card(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outline.withValues(alpha: 0.55)),
        ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'BMI $estimatedBmi',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: statusColor.withValues(alpha: 0.28)),
                      ),
                      child: Text(
                        status.toUpperCase(),
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Height: $heightDetected cm    Weight: $weightEstimated kg',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        createdAt,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BmiHistoryDetailPage extends StatefulWidget {
  const _BmiHistoryDetailPage({
    required this.measurementId,
    required this.userApiService,
  });

  final int measurementId;
  final UserApiService userApiService;

  @override
  State<_BmiHistoryDetailPage> createState() => _BmiHistoryDetailPageState();
}

class _BmiHistoryDetailPageState extends State<_BmiHistoryDetailPage> {
  late Future<ApiResult> _detailFuture;

  @override
  void initState() {
    super.initState();
    _detailFuture = widget.userApiService.getBmiDetail(widget.measurementId);
  }

  Future<void> _reload() async {
    setState(() {
      _detailFuture = widget.userApiService.getBmiDetail(widget.measurementId);
    });
    await _detailFuture;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('Measurement #${widget.measurementId}')),
      body: FutureBuilder<ApiResult>(
        future: _detailFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: BmiLoader(showLabel: true, label: 'Loading measurement…'),
            );
          }

          final result = snapshot.data;
          if (snapshot.hasError || result == null || !result.ok) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Unable to load measurement detail.',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      result?.message ?? 'Please try again.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          final data = result.data is Map ? result.data as Map : const <String, dynamic>{};
          final videoUrl = (data['video_url'] ?? '').toString();
          final status = (data['status'] ?? 'unknown').toString();
          final statusColor = _historyStatusColor(status, scheme);

          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                if (videoUrl.isNotEmpty) ...[
                  _NetworkVideoPreview(videoUrl: videoUrl),
                  const SizedBox(height: 12),
                ],
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: BorderSide(color: scheme.outline.withValues(alpha: 0.55)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'BMI ${(data['estimated_bmi'] ?? '--')}',
                                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: statusColor.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: statusColor.withValues(alpha: 0.28)),
                              ),
                              child: Text(
                                status.toUpperCase(),
                                style: TextStyle(
                                  color: statusColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _detailRow(context, 'Height detected', '${data['height_detected'] ?? '--'} cm'),
                        _detailRow(context, 'Weight estimated', '${data['weight_estimated'] ?? '--'} kg'),
                        _detailRow(context, 'Face match score', (data['face_match_score'] ?? '--').toString()),
                        _detailRow(context, 'Created', _formatHistoryDateTime((data['createdAt'] ?? '').toString())),
                        _detailRow(context, 'Updated', _formatHistoryDateTime((data['updatedAt'] ?? '').toString())),
                        _detailRow(context, 'Admin notes', (data['admin_notes'] ?? '—').toString()),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _detailRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _ProfileTab extends StatefulWidget {
  const _ProfileTab({required this.userApiService, required this.onLogout});

  final UserApiService userApiService;
  final Future<void> Function() onLogout;

  @override
  State<_ProfileTab> createState() => _ProfileTabState();
}

class _NetworkVideoPreview extends StatefulWidget {
  const _NetworkVideoPreview({required this.videoUrl});

  final String videoUrl;

  @override
  State<_NetworkVideoPreview> createState() => _NetworkVideoPreviewState();
}

class _NetworkVideoPreviewState extends State<_NetworkVideoPreview> {
  VideoPlayerController? _controller;
  bool _initializing = true;
  String? _error;
  bool _isMuted = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final uri = Uri.tryParse(widget.videoUrl);
    if (uri == null) {
      setState(() {
        _initializing = false;
        _error = 'Invalid video URL';
      });
      return;
    }

    try {
      final controller = VideoPlayerController.networkUrl(uri);
      await controller.initialize();
      controller.setLooping(true);
      controller.addListener(_onVideoTick);
      if (!mounted) {
        controller.removeListener(_onVideoTick);
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _initializing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = 'Unable to load video preview';
      });
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onVideoTick);
    _controller?.dispose();
    super.dispose();
  }

  void _onVideoTick() {
    if (!mounted) return;
    setState(() {});
  }

  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _toggleMute() async {
    final controller = _controller;
    if (controller == null) return;
    final nextMuted = !_isMuted;
    await controller.setVolume(nextMuted ? 0 : 1);
    if (!mounted) return;
    setState(() {
      _isMuted = nextMuted;
    });
  }

  Future<void> _openFullScreen() async {
    final controller = _controller;
    if (controller == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _FullScreenVideoPlayer(
          controller: controller,
          isMuted: _isMuted,
          onMuteToggle: _toggleMute,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final controller = _controller;
    final position = controller?.value.position ?? Duration.zero;
    final duration = controller?.value.duration ?? Duration.zero;
    final maxPosition = duration > Duration.zero ? duration : const Duration(seconds: 1);
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outline.withValues(alpha: 0.55)),
      ),
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: Container(
        color: Colors.black,
        child: AspectRatio(
          aspectRatio: _controller?.value.aspectRatio ?? 16 / 9,
          child: _initializing
              ? const Center(
                  child: BmiLoader(showLabel: true, label: 'Loading video…'),
                )
              : _error != null
              ? Center(
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.white70),
                  ),
                )
              : Stack(
                  children: [
                    Positioned.fill(child: VideoPlayer(controller!)),
                    Positioned(
                      right: 10,
                      bottom: 10,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: IconButton(
                          onPressed: () {
                            if (controller.value.isPlaying) {
                              controller.pause();
                            } else {
                              controller.play();
                            }
                            setState(() {});
                          },
                          icon: Icon(
                            controller.value.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 10,
                      bottom: 10,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: IconButton(
                          onPressed: _toggleMute,
                          icon: Icon(
                            _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 10,
                      top: 10,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: IconButton(
                          onPressed: _openFullScreen,
                          icon: const Icon(
                            Icons.fullscreen_rounded,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 10,
                      right: 10,
                      bottom: 62,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          VideoProgressIndicator(
                            controller,
                            allowScrubbing: true,
                            colors: VideoProgressColors(
                              playedColor: scheme.primary,
                              bufferedColor: Colors.white54,
                              backgroundColor: Colors.white24,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Text(
                                _formatDuration(position),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                _formatDuration(maxPosition),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _FullScreenVideoPlayer extends StatefulWidget {
  const _FullScreenVideoPlayer({
    required this.controller,
    required this.isMuted,
    required this.onMuteToggle,
  });

  final VideoPlayerController controller;
  final bool isMuted;
  final Future<void> Function() onMuteToggle;

  @override
  State<_FullScreenVideoPlayer> createState() => _FullScreenVideoPlayerState();
}

class _FullScreenVideoPlayerState extends State<_FullScreenVideoPlayer> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTick);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (!mounted) return;
    setState(() {});
  }

  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final position = controller.value.position;
    final duration = controller.value.duration;
    final maxPosition = duration > Duration.zero ? duration : const Duration(seconds: 1);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio == 0
                    ? 16 / 9
                    : controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            ),
            Positioned(
              top: 12,
              left: 12,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
            ),
            Positioned(
              right: 12,
              top: 12,
              child: IconButton(
                onPressed: widget.onMuteToggle,
                icon: Icon(
                  widget.isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                  color: Colors.white,
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 28,
              child: Column(
                children: [
                  VideoProgressIndicator(
                    controller,
                    allowScrubbing: true,
                    colors: const VideoProgressColors(
                      playedColor: Colors.white,
                      bufferedColor: Colors.white54,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text(
                        _formatDuration(position),
                        style: const TextStyle(color: Colors.white),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: () {
                          if (controller.value.isPlaying) {
                            controller.pause();
                          } else {
                            controller.play();
                          }
                          setState(() {});
                        },
                        icon: Icon(
                          controller.value.isPlaying
                              ? Icons.pause_circle_filled_rounded
                              : Icons.play_circle_fill_rounded,
                          color: Colors.white,
                          size: 34,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _formatDuration(maxPosition),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileTabState extends State<_ProfileTab> {
  bool _didLoadProfileOnce = false;
  late Future<ApiResult> _profileFuture;
  final SessionStorageService _sessionStorageService = SessionStorageService();
  bool _governmentIdUploaded = false;

  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _mobileController = TextEditingController();
  final _dobController = TextEditingController();
  final _heightController = TextEditingController();
  final _weightController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _profileFuture = widget.userApiService.getProfile();
    _loadGovernmentIdFlag();
  }

  Future<void> _loadGovernmentIdFlag() async {
    final uploaded = await _sessionStorageService.getGovernmentIdUploaded();
    if (!mounted) return;
    setState(() {
      _governmentIdUploaded = uploaded;
    });
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

  Future<void> _loadIntoControllers(dynamic profileData) async {
    if (profileData is! Map) return;

    _firstNameController.text =
        (profileData['first_name'] ?? profileData['firstName'] ?? '')
            .toString();
    _lastNameController.text =
        (profileData['last_name'] ?? profileData['lastName'] ?? '').toString();
    _mobileController.text =
        (profileData['mobile_number'] ?? profileData['mobile'] ?? '')
            .toString();
    _dobController.text = _formatDateForDisplay(
      (profileData['dob'] ?? '').toString(),
    );
    _heightController.text =
        (profileData['height_cm'] ?? profileData['heightCm'] ?? '').toString();
    _weightController.text =
        (profileData['weight_kg'] ?? profileData['weightKg'] ?? '').toString();
  }

  String? _extractPhotoUrl(dynamic profileData) {
    if (profileData is! Map) return null;
    final dynamic photo =
        profileData['profile_photo'] ??
        profileData['profilePhoto'] ??
        profileData['profile_photo_url'] ??
        profileData['profilePhotoUrl'] ??
        profileData['profile_photoUrl'];
    if (photo == null) return null;
    if (photo is String) {
      final s = photo.trim();
      return s.isEmpty ? null : s;
    }
    if (photo is Map) {
      final dynamic url = photo['url'] ?? photo['path'] ?? photo['href'];
      if (url is String) {
        final s = url.trim();
        return s.isEmpty ? null : s;
      }
    }
    final s = photo.toString().trim();
    return s.isEmpty ? null : s;
  }

  String? _documentIdVerifiedStatus(dynamic profileData) {
    if (profileData is! Map) return null;
    final raw = profileData['document_id_verified'];
    final s = raw?.toString().trim().toLowerCase();
    if (s == null || s.isEmpty) return null;
    return s;
  }

  Widget? _buildIdentityStatusBanner(dynamic profileData) {
    final scheme = Theme.of(context).colorScheme;
    final rawStatus = _documentIdVerifiedStatus(profileData);
    final normalized = rawStatus ?? (_governmentIdUploaded ? 'pending' : null);
    if (normalized == null) return null;

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
        ? 'Please update your document to verify your identity.'
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
                    'You can update your ID anytime from Account preferences.',
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
  Widget build(BuildContext context) {
    return FutureBuilder<ApiResult>(
      future: _profileFuture,
      builder: (context, snapshot) {
        final state = snapshot.connectionState;
        if (state == ConnectionState.waiting) {
          return const Center(child: BmiLoader(showLabel: true));
        }

        if (snapshot.hasError) {
          return const Center(child: Text('Failed to load profile.'));
        }

        final result = snapshot.data;
        final profileData = result?.data;
        if (result == null || !result.ok) {
          return const Center(child: Text('Unable to fetch profile.'));
        }

        if (!_didLoadProfileOnce) {
          _didLoadProfileOnce = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _loadIntoControllers(profileData);
            if (mounted) setState(() {});
          });
        }

        final photoUrl = _extractPhotoUrl(profileData);
        ImageProvider? avatarProvider;
        if (photoUrl != null && photoUrl.isNotEmpty) {
          avatarProvider = NetworkImage(photoUrl);
        }

        final identityBanner = _buildIdentityStatusBanner(profileData);
        final scheme = Theme.of(context).colorScheme;

        return _ResponsiveTabContainer(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _PremiumHeader(
                title: 'My Profile',
                subtitle: 'Manage your account settings and preferences.',
              ),
              const SizedBox(height: 16),
              Card(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                  side: BorderSide(color: scheme.outline.withValues(alpha: 0.65)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 36,
                        backgroundColor: scheme.surfaceContainerHighest,
                        foregroundColor: scheme.onSurfaceVariant,
                        backgroundImage: avatarProvider,
                        child: avatarProvider == null
                            ? const Icon(Icons.person_rounded, size: 28)
                            : null,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_firstNameController.text} ${_lastNameController.text}'
                                  .trim()
                                  .ifEmpty('Clockwork User'),
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _mobileController.text.trim().ifEmpty(
                                'No phone number',
                              ),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (identityBanner != null) ...[
                const SizedBox(height: 12),
                identityBanner,
              ],
              const SizedBox(height: 12),
              const _SettingsSectionHeader(title: 'Account'),
              Card(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                  side: BorderSide(color: scheme.outline.withValues(alpha: 0.65)),
                ),
                child: Column(
                  children: [
                    _SettingsTile(
                      icon: Icons.person_outline,
                      title: 'Account preferences',
                      onTap: () async {
                        final changed = await Navigator.push<bool>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => _EditProfilePage(
                              userApiService: widget.userApiService,
                              firstName: _firstNameController.text,
                              lastName: _lastNameController.text,
                              mobileNumber: _mobileController.text,
                              dob: _dobController.text,
                              heightCm: _heightController.text,
                              weightKg: _weightController.text,
                              currentPhotoUrl: photoUrl,
                            ),
                          ),
                        );
                        if (changed == true && mounted) {
                          _didLoadProfileOnce = false;
                          setState(() {
                            _profileFuture = widget.userApiService.getProfile();
                          });
                        }
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const _SettingsSectionHeader(title: 'Support & Preferences'),
              Card(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                  side: BorderSide(color: scheme.outline.withValues(alpha: 0.65)),
                ),
                child: Column(
                  children: [
                    _SettingsTile(
                      icon: Icons.notifications_outlined,
                      title: 'Notifications',
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => _NotificationsPage(
                              userApiService: widget.userApiService,
                            ),
                          ),
                        );
                      },
                    ),
                    const Divider(height: 0, indent: 60, endIndent: 12),
                    _SettingsTile(
                      icon: Icons.info_outline,
                      title: 'About Clockwork',
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const _AboutPage()),
                        );
                      },
                    ),
                    const Divider(height: 0, indent: 60, endIndent: 12),
                    _SettingsTile(
                      icon: Icons.privacy_tip_outlined,
                      title: 'Privacy Policy',
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const _PrivacyPolicyPage(),
                          ),
                        );
                      },
                    ),
                    const Divider(height: 0, indent: 60, endIndent: 12),
                    _SettingsTile(
                      icon: Icons.square_foot_outlined,
                      title: 'Recalibrate Height (AR)',
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const HeightCalibrationScreen(),
                          ),
                        );
                      },
                    ),
                    const Divider(height: 0, indent: 60, endIndent: 12),
                    _SettingsTile(
                      icon: Icons.logout,
                      title: 'Logout',
                      onTap: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('Logout?'),
                            content: const Text(
                              'Are you sure you want to logout from your account?',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, false),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, true),
                                child: const Text('Logout'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true) {
                          await widget.onLogout();
                        }
                      },
                    ),
                    const Divider(height: 0, indent: 60, endIndent: 12),
                    _SettingsTile(
                      icon: Icons.delete_forever_outlined,
                      title: 'Delete Account',
                      accentColor: Colors.red,
                      onTap: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('Delete account?'),
                            content: const Text(
                              'This action cannot be undone.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, false),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, true),
                                child: const Text(
                                  'Delete',
                                  style: TextStyle(color: Colors.red),
                                ),
                              ),
                            ],
                          ),
                        );

                        if (confirmed != true) return;

                        final res = await widget.userApiService.deleteAccount();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              res.ok
                                  ? 'Account deleted'
                                  : (res.message ?? 'Delete failed'),
                            ),
                          ),
                        );
                        if (res.ok) {
                          await widget.onLogout();
                        }
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EditProfilePage extends StatefulWidget {
  const _EditProfilePage({
    required this.userApiService,
    required this.firstName,
    required this.lastName,
    required this.mobileNumber,
    required this.dob,
    required this.heightCm,
    required this.weightKg,
    required this.currentPhotoUrl,
  });

  final UserApiService userApiService;
  final String firstName;
  final String lastName;
  final String mobileNumber;
  final String dob;
  final String heightCm;
  final String weightKg;
  final String? currentPhotoUrl;

  @override
  State<_EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<_EditProfilePage> {
  final _picker = ImagePicker();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _mobileController = TextEditingController();
  final _dobController = TextEditingController();
  final _heightController = TextEditingController();
  final _weightController = TextEditingController();

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _firstNameController.text = widget.firstName;
    _lastNameController.text = widget.lastName;
    _mobileController.text = widget.mobileNumber;
    _dobController.text = _normalizeDobForDisplay(widget.dob);
    _heightController.text = widget.heightCm;
    _weightController.text = widget.weightKg;
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

  Future<void> _uploadGovernmentId() async {
    final xFile = await _picker.pickImage(source: ImageSource.gallery);
    if (xFile == null) return;
    final idFile = File(xFile.path);
    final res = await widget.userApiService.uploadGovernmentId(
      idDocumentFile: idFile,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          res.ok
              ? (res.message ??
                    'ID uploaded. Profile photo will update after backend verification.')
              : (res.message ?? 'ID upload failed'),
        ),
      ),
    );
    if (!mounted) return;
    if (res.ok) {
      // Let the parent refresh `/profile` and show the updated verification status/photo.
      Navigator.pop(context, true);
    }
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
      setState(() {
        _dobController.text = _toDisplayDate(tempPicked);
      });
      return;
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: minDate,
      lastDate: maxDate,
    );
    if (picked != null) {
      setState(() {
        _dobController.text = _toDisplayDate(picked);
      });
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

    // Already in DD/MM/YYYY.
    if (_parseDisplayDate(value) != null) return value;

    // Convert YYYY-MM-DD from API to DD/MM/YYYY.
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

  @override
  Widget build(BuildContext context) {
    final avatarProvider =
        (widget.currentPhotoUrl != null && widget.currentPhotoUrl!.isNotEmpty)
        ? NetworkImage(widget.currentPhotoUrl!)
        : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Account preferences')),
      body: _ResponsivePageContainer(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Center(
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  CircleAvatar(
                    radius: 56,
                    backgroundColor: Colors.grey.shade200,
                    backgroundImage: avatarProvider as ImageProvider<Object>?,
                    child: avatarProvider == null
                        ? const Icon(Icons.person, size: 40)
                        : null,
                  ),
                  IconButton(
                    onPressed: _uploadGovernmentId,
                    icon: const CircleAvatar(
                      radius: 18,
                      child: Icon(Icons.badge_outlined, size: 18),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _uploadGovernmentId,
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('Update Government ID'),
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
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Height (cm)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _weightController,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Weight (kg)'),
            ),
            const SizedBox(height: 14),
            _BmiPreviewCard(
              bmi: _calculateBmi(
                _heightController.text.trim(),
                _weightController.text.trim(),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _saving
                  ? null
                  : () async {
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
                          const SnackBar(
                            content: Text('Please fill all profile fields.'),
                          ),
                        );
                        return;
                      }

                      if (!_isValidMobileNumber(mobileNumber)) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Enter a valid mobile number (10-15 digits).',
                            ),
                          ),
                        );
                        return;
                      }

                      final dob = _formatDateForApi(dobInput);
                      if (dob == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('DOB must be in DD/MM/YYYY format.'),
                          ),
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
                      setState(() => _saving = false);

                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            res.ok
                                ? 'Profile updated'
                                : (res.message ?? 'Update failed'),
                          ),
                        ),
                      );
                      if (res.ok) Navigator.pop(context, true);
                    },
              child: _saving
                  ? const BmiLoader(size: 20, strokeWidth: 2)
                  : const Text('Save Profile'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BmiPreviewCard extends StatelessWidget {
  const _BmiPreviewCard({required this.bmi});

  final double? bmi;

  @override
  Widget build(BuildContext context) {
    final display = bmi == null ? '--' : bmi!.toStringAsFixed(1);
    final category = bmi == null
        ? 'Enter height and weight'
        : _bmiCategory(bmi!);
    final color = bmi == null ? Colors.grey : _bmiColor(bmi!);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.monitor_heart_outlined, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'BMI (Preview only)',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  'Based on entered height/weight',
                  style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                display,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
              Text(
                category,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NotificationsPage extends StatelessWidget {
  const _NotificationsPage({required this.userApiService});

  final UserApiService userApiService;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: _ResponsivePageContainer(
        child: FutureBuilder<ApiResult>(
          future: userApiService.getNotifications(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: BmiLoader(showLabel: true));
            }
            final result = snapshot.data;
            if (result == null || !result.ok) {
              return const Center(child: Text('Unable to load notifications.'));
            }

            final data = result.data;
            if (data is! List || data.isEmpty) {
              return const Center(child: Text('No notifications yet.'));
            }

            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemBuilder: (context, index) {
                final item = data[index];
                final title = item is Map
                    ? (item['title'] ?? item['body'])
                    : null;
                final body = item is Map
                    ? (item['body'] ?? item['message'])
                    : null;
                return ListTile(
                  title: Text(title?.toString() ?? 'Notification'),
                  subtitle: body == null ? null : Text(body.toString()),
                );
              },
              separatorBuilder: (context, index) => const Divider(height: 0),
              itemCount: data.length,
            );
          },
        ),
      ),
    );
  }
}

class _AboutPage extends StatelessWidget {
  const _AboutPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About Clockwork')),
      body: _ResponsivePageContainer(
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Clockwork BMI provides modern body measurement experiences using pose detection and secure workflows.',
            style: TextStyle(height: 1.5),
          ),
        ),
      ),
    );
  }
}

class _PrivacyPolicyPage extends StatelessWidget {
  const _PrivacyPolicyPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Policy')),
      body: _ResponsivePageContainer(
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Privacy Policy content goes here. Add your terms and data handling details.',
            style: TextStyle(height: 1.5),
          ),
        ),
      ),
    );
  }
}

class _PremiumHeader extends StatelessWidget {
  const _PremiumHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
            height: 1.12,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 3,
          height: 20,
          decoration: BoxDecoration(
            color: scheme.tertiary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}

class _ResponsiveTabContainer extends StatelessWidget {
  const _ResponsiveTabContainer({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isTablet = size.shortestSide >= 600;
    final topInset = MediaQuery.paddingOf(context).top;
    final topSpacing = (isTablet ? 24.0 : 12.0) + (topInset > 0 ? 4.0 : 0.0);

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isTablet ? 760 : 560),
        child: Padding(
          padding: EdgeInsets.only(top: topSpacing),
          child: child,
        ),
      ),
    );
  }
}

class _ResponsivePageContainer extends StatelessWidget {
  const _ResponsivePageContainer({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isTablet = size.shortestSide >= 600;
    final topInset = MediaQuery.paddingOf(context).top;
    final topSpacing = (isTablet ? 20.0 : 10.0) + (topInset > 0 ? 4.0 : 0.0);

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isTablet ? 760 : 560),
        child: Padding(
          padding: EdgeInsets.only(top: topSpacing),
          child: child,
        ),
      ),
    );
  }
}

class _SettingsSectionHeader extends StatelessWidget {
  const _SettingsSectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10, top: 2),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          fontSize: 11,
          letterSpacing: 1.35,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.accentColor,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = accentColor ?? scheme.primary;
    return Material(
      color: Colors.transparent,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        minLeadingWidth: 44,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        splashColor: color.withValues(alpha: 0.10),
        hoverColor: color.withValues(alpha: 0.05),
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.11),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        title: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: accentColor ?? scheme.onSurface,
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
        trailing: Icon(
          Icons.chevron_right_rounded,
          color: accentColor ?? scheme.onSurfaceVariant,
        ),
        onTap: onTap,
      ),
    );
  }
}

extension _StringFallback on String {
  String ifEmpty(String fallback) => trim().isEmpty ? fallback : this;
}

double? _calculateBmi(String heightCmRaw, String weightKgRaw) {
  final h = double.tryParse(heightCmRaw);
  final w = double.tryParse(weightKgRaw);
  if (h == null || w == null || h <= 0 || w <= 0) return null;
  final meters = h / 100.0;
  if (meters <= 0) return null;
  return w / (meters * meters);
}

String _bmiCategory(double bmi) {
  if (bmi < 18.5) return 'Underweight';
  if (bmi < 25) return 'Normal';
  if (bmi < 30) return 'Overweight';
  return 'Obese';
}

Color _bmiColor(double bmi) {
  if (bmi < 18.5) return Colors.blue;
  if (bmi < 25) return Colors.green;
  if (bmi < 30) return Colors.orange;
  return Colors.red;
}

String _formatDateForDisplay(String apiDate) {
  final raw = apiDate.trim();
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(raw);
  if (match == null) return raw;
  final year = match.group(1)!;
  final month = match.group(2)!;
  final day = match.group(3)!;
  return '$day/$month/$year';
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

String _formatHistoryDateTime(String raw) {
  if (raw.trim().isEmpty) return 'Date unavailable';
  final date = DateTime.tryParse(raw)?.toLocal();
  if (date == null) return raw;
  final dd = date.day.toString().padLeft(2, '0');
  final mm = date.month.toString().padLeft(2, '0');
  final yyyy = date.year.toString();
  final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
  final min = date.minute.toString().padLeft(2, '0');
  final ampm = date.hour >= 12 ? 'PM' : 'AM';
  return '$dd/$mm/$yyyy • $hour:$min $ampm';
}

Color _historyStatusColor(String status, ColorScheme scheme) {
  switch (status.trim().toLowerCase()) {
    case 'completed':
    case 'success':
      return const Color(0xFF2A6B4A);
    case 'failed':
    case 'rejected':
      return scheme.error;
    case 'pending':
    default:
      return scheme.primary;
  }
}
